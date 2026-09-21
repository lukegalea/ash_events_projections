# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Server do
  @moduledoc """
  One GenServer per projector. Owns the drain loop — boot replay, live event
  signals, and synchronous flush are all the same code path.

  Registered globally via `:global` so only one process runs cluster-wide
  per projector name. In a multi-node cluster a second node starting the same
  projector receives `{:error, {:already_started, pid}}` from start_link and
  the supervisor skips it; the primary node remains authoritative.

  ## Drain semantics

  Each event is processed in its own database transaction together with the
  matching `Checkpoint.advance` call. Three outcomes:

    * **Success** — projection ops + checkpoint advance commit atomically.
    * **Handler raise** — per-event transaction rolls back, no partial writes.
      A DLQ row is then inserted (in a fresh transaction) and the checkpoint
      advances past the offending event so the projector keeps flowing.
    * **Rebuilding** — the projector's `Registry` row is `:rebuilding`. The
      drain short-circuits to `:idle`; the next poll picks up where it left
      off once the rebuild flips status back to `:active`.
  """

  use GenServer
  import Ecto.Query
  require Ash.Query
  require Logger

  alias AshEvents.Projections.{Checkpoint, DeadLetter, Registry}
  alias AshEvents.Projections.Config

  @batch_size 500

  def start_link(projector) do
    GenServer.start_link(__MODULE__, projector,
      name: {:global, {__MODULE__, projector.__projector_name__()}}
    )
  end

  @doc "Signal the server that new events are available (non-blocking)."
  def notify(projector_name) do
    case :global.whereis_name({__MODULE__, projector_name}) do
      :undefined -> :ok
      pid -> GenServer.cast(pid, :process)
    end
  end

  @doc """
  Drain all pending events synchronously.

  Safe to call in tests after creating events — blocks until the projector
  has processed everything up to the current watermark.
  """
  def flush(projector_name) do
    case :global.whereis_name({__MODULE__, projector_name}) do
      :undefined -> :ok
      pid -> GenServer.call(pid, :flush, 30_000)
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(projector) do
    # Observable in :observer and process listings (OTP 26+ process labels).
    :proc_lib.set_label({:projector, projector.__projector_name__()})
    Registry.initialize(projector.__projector_name__())
    send(self(), :process)
    {:ok, %{projector: projector, status: :running}}
  end

  @impl true
  def handle_cast(:process, %{status: :running} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:process, %{status: :idle} = state) do
    Logger.info("[Projections] Server received :process, starting drain")
    send(self(), :process)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_info(:process, %{projector: projector} = state) do
    status = drain(projector)
    {:noreply, %{state | status: status}}
  end

  @impl true
  def handle_call(:flush, _from, %{projector: projector} = state) do
    status = drain(projector)
    {:reply, :ok, %{state | status: status}}
  end

  # --- Internal ---

  defp drain(projector) do
    if rebuilding?(projector) do
      Logger.debug(
        "[Projections] #{projector.__projector_name__()} drain: registry status=:rebuilding, skipping"
      )

      :idle
    else
      do_drain(projector)
    end
  end

  defp do_drain(projector) do
    checkpoint = get_or_create_checkpoint(projector)
    after_id = checkpoint.last_seen_event_id || 0

    batch =
      from(e in Config.event_table(),
        select: %{
          id: e.id,
          practice_id: e.practice_id,
          user_id: e.user_id,
          occurred_at: e.occurred_at,
          metadata: e.metadata,
          resource: e.resource,
          action: e.action,
          action_type: e.action_type
        },
        where: e.id > ^after_id,
        order_by: [asc: e.id],
        limit: @batch_size
      )
      |> Config.repo().all()
      |> Enum.map(&normalize_event_row/1)

    case batch do
      [] ->
        Logger.debug("[Projections] #{projector.__projector_name__()} drain: no new events, idle")

        :idle

      events ->
        Logger.info(
          "[Projections] #{projector.__projector_name__()} drain: processing #{length(events)} event(s)"
        )

        Enum.each(events, &process_event(projector, &1))
        do_drain(projector)
    end
  end

  # Per-event transaction: ops + checkpoint advance commit atomically.
  # If the handler raises, the transaction rolls back and we route the
  # event to the DLQ in a fresh transaction, then advance the checkpoint
  # past it so the projector keeps flowing.
  defp process_event(projector, event) do
    fn ->
      apply_event(projector, event)
      checkpoint = get_or_create_checkpoint(projector)
      Checkpoint.advance(checkpoint, event.id)
    end
    |> Config.repo().transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> handle_failure(projector, event, reason, [])
    end
  rescue
    error -> handle_failure(projector, event, error, __STACKTRACE__)
  end

  # Two paths based on whether the handler needs to read the current row first.
  #
  # Stateless (arity 1): handler(event) → ops | skip
  #   - Call handler FIRST; skip DB hit entirely if it returns :skip.
  #   - Load grain row only when we have ops to apply.
  #
  # Stateful (arity 2): handler(event, current_row) → ops | skip
  #   - Load (or create) grain row FIRST, then call handler with current state.
  #   - Row is already in hand, so no extra DB round-trip for the update.
  #   - Useful for running averages, ratios, or any derived value that depends
  #     on the existing projection state.
  defp apply_event(projector, event) do
    resource = projector.__projection_resource__()

    with grain_key when not is_nil(grain_key) <- projector.__grain__().(event) do
      apply_grain_ops(projector, event, resource, grain_key)
    end
  end

  defp apply_grain_ops(projector, event, resource, grain_key) do
    if projector.needs_current_state?(event) do
      row = get_or_upsert_grain(resource, grain_key)

      case projector.handle_event(event, row) do
        {:ok, ops} when ops != [] -> apply_ops!(row, ops)
        _ -> :ok
      end
    else
      apply_stateless(projector, event, resource, grain_key)
    end
  end

  # Stateless (arity 1): call handler first; skip the DB hit entirely when it
  # returns :skip or empty ops.
  defp apply_stateless(projector, event, resource, grain_key) do
    case projector.handle_event(event) do
      {:ok, ops} when ops != [] ->
        row = get_or_upsert_grain(resource, grain_key)
        apply_ops!(row, ops)

      _ ->
        :ok
    end
  end

  defp apply_ops!(row, ops) do
    Ash.update!(row, %{ops: ops}, action: :apply_projection_ops, authorize?: false)
  end

  defp handle_failure(projector, event, error, stacktrace) do
    name = projector.__projector_name__()

    Logger.error(
      "[Projections] #{name} event ##{event.id} (#{event.resource}.#{event.action}) raised: " <>
        Exception.format(:error, error, stacktrace)
    )

    Config.repo().transaction(fn ->
      DeadLetter.record_failure(%{
        projection_name: name,
        event_id: event.id,
        error_class: error_class(error),
        error_message: error_message(error),
        stacktrace: format_stacktrace(stacktrace),
        failed_at: DateTime.utc_now()
      })

      checkpoint = get_or_create_checkpoint(projector)
      Checkpoint.advance(checkpoint, event.id)
    end)
  rescue
    e ->
      # If the DLQ insert itself fails, log and let the projector loop crash;
      # LeaderMonitor will restart it and we'll re-attempt this event next
      # drain. Better than silently swallowing the failure.
      Logger.critical(
        "[Projections] #{projector.__projector_name__()} DLQ write failed for event ##{event.id}: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      reraise e, __STACKTRACE__
  end

  defp rebuilding?(projector) do
    name = projector.__projector_name__()

    case Ash.get(Registry, name, authorize?: false) do
      {:ok, %{status: :rebuilding}} -> true
      _ -> false
    end
  end

  # grain_key is either a map (%{practice_id: "x", billing_period_start: ~D[...]})
  # or a scalar value for single-field grains.
  defp get_or_upsert_grain(resource, grain_key) when is_map(grain_key) do
    Ash.create!(resource, grain_key, action: :upsert_grain, authorize?: false)
  end

  defp get_or_upsert_grain(resource, grain_key) do
    [grain_field] = resource.__projection_grain_fields__()
    Ash.create!(resource, %{grain_field => grain_key}, action: :upsert_grain, authorize?: false)
  end

  defp normalize_event_row(row) do
    %{
      id: row.id,
      practice_id: uuid_to_string(row.practice_id),
      user_id: uuid_to_string(row.user_id),
      occurred_at: row.occurred_at,
      metadata: row.metadata || %{},
      resource: to_atom(row.resource),
      action: to_atom(row.action),
      action_type: to_atom(row.action_type)
    }
  end

  # Postgrex returns PostgreSQL uuid columns as raw 16-byte binaries when querying
  # without a schema (as Server.drain does via `from(e in "ash_events", ...)`).
  defp uuid_to_string(nil), do: nil

  defp uuid_to_string(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    {:ok, s} = Ecto.UUID.load(uuid)
    s
  end

  defp uuid_to_string(uuid), do: uuid

  # Use to_existing_atom/1: every legitimate value here is a module or action
  # name that has already been loaded (resources are compiled at boot, actions
  # are atoms in the resource DSL). Raising on unknown strings keeps malformed
  # rows visible instead of silently growing the atom table.
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(nil), do: nil

  defp get_or_create_checkpoint(projector) do
    {:ok, cp} = Checkpoint.initialize(projector.__projector_name__())
    cp
  end

  defp error_class(%mod{}), do: inspect(mod)
  defp error_class(_), do: "Unknown"

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(other), do: inspect(other)

  defp format_stacktrace([]), do: nil
  defp format_stacktrace(stacktrace), do: Exception.format_stacktrace(stacktrace)
end
