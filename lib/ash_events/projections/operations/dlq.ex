# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Operations.Dlq do
  @moduledoc """
  Inspect, replay, and purge dead-letter rows for a projector.

  When `AshEvents.Projections.Server` traps an exception during `apply_event`
  it inserts a row into `ash_projection_dead_letter_events` and advances the
  checkpoint past the offending event. That keeps the projector flowing,
  but those events now need an explicit operator action — either fix the
  handler and replay them, or decide they are intentionally unprocessable
  and purge.

  ## Replay

  `replay/2` re-runs the offending events through the live projector module
  WITHOUT rolling back the checkpoint. Each event is applied in its own
  transaction. On success the DLQ row is marked `:replayed`; on failure
  the row is updated with the new error and stays in `:failed`.

  This avoids the double-count risk of rewinding the checkpoint (which would
  re-process every event since the failure, including ones that succeeded).

  """

  alias AshEvents.Projections.{Config, DeadLetter, EventRow, Server}

  import Ecto.Query

  require Ash.Query
  require Logger

  @doc "Returns DLQ rows for a single projector, optionally filtered by status."
  @spec list(String.t(), keyword()) :: [map()]
  def list(projector_name, opts \\ []) do
    statuses = Keyword.get(opts, :statuses, [:failed, :pending_replay])

    DeadLetter
    |> Ash.Query.filter(projection_name == ^projector_name and status in ^statuses)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  Replays DLQ rows back through the live projector module.

  By default replays everything in `:failed` status for the projector.
  Pass `:event_ids` to scope to specific events.

  Returns `%{replayed: n, failed: m, skipped: k}`.
  """
  @spec replay(module(), keyword()) :: %{
          replayed: integer(),
          failed: integer(),
          skipped: integer()
        }
  def replay(projector_module, opts \\ []) do
    name = projector_module.__projector_name__()
    Server.flush(name)

    rows = fetch_replay_candidates(name, opts)

    Enum.reduce(rows, %{replayed: 0, failed: 0, skipped: 0}, fn dlq, acc ->
      replay_row(projector_module, dlq, name, acc)
    end)
  end

  defp replay_row(projector_module, dlq, name, acc) do
    partition_column = EventRow.partition_column(projector_module)

    case load_event(dlq.event_id, partition_column) do
      nil ->
        DeadLetter.mark_purged(dlq)
        %{acc | skipped: acc.skipped + 1}

      event ->
        settle_replay(projector_module, dlq, event, name, acc)
    end
  end

  defp settle_replay(projector_module, dlq, event, name, acc) do
    case attempt_replay(projector_module, event) do
      :ok ->
        DeadLetter.mark_replayed(dlq)
        %{acc | replayed: acc.replayed + 1}

      {:error, reason} ->
        Logger.warning(
          "[Projections.Dlq] replay of event ##{dlq.event_id} for #{name} still failing: #{inspect(reason)}"
        )

        %{acc | failed: acc.failed + 1}
    end
  end

  @doc "Marks DLQ rows as `:purged` (kept for audit). Pass `:hard_delete?: true` to remove them."
  @spec purge(String.t(), keyword()) :: integer()
  def purge(projector_name, opts \\ []) do
    rows = list(projector_name, opts)

    if Keyword.get(opts, :hard_delete?, false) do
      Enum.each(rows, &DeadLetter.purge/1)
    else
      Enum.each(rows, &DeadLetter.mark_purged/1)
    end

    length(rows)
  end

  defp fetch_replay_candidates(name, opts) do
    statuses = Keyword.get(opts, :statuses, [:failed, :pending_replay])

    DeadLetter
    |> Ash.Query.filter(projection_name == ^name and status in ^statuses)
    |> filter_by_ids(opts[:event_ids])
    |> Ash.read!(authorize?: false)
  end

  defp filter_by_ids(query, nil), do: query
  defp filter_by_ids(query, []), do: query
  defp filter_by_ids(query, ids), do: Ash.Query.filter(query, event_id in ^ids)

  defp load_event(id, partition_column) do
    Config.event_table()
    |> EventRow.query(partition_column)
    |> where([e], e.id == ^id)
    |> Config.repo().one()
    |> case do
      nil -> nil
      row -> EventRow.normalize(row, partition_column)
    end
  end

  defp attempt_replay(projector_module, event) do
    Config.repo().transaction(fn ->
      replay_event(projector_module, event)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp replay_event(projector_module, event) do
    grain_fn = projector_module.__grain__()
    resource = projector_module.__projection_resource__()

    case grain_fn.(event) do
      nil -> :ok
      grain_key -> replay_grain(projector_module, event, resource, grain_key)
    end
  end

  defp replay_grain(projector_module, event, resource, grain_key) do
    row = upsert_grain(resource, grain_key)

    if projector_module.needs_current_state?(event) do
      apply_handler_ops(projector_module.handle_event(event, row), row)
    else
      apply_handler_ops(projector_module.handle_event(event), row)
    end
  end

  defp apply_handler_ops({:ok, ops}, row) when ops != [] do
    Ash.update!(row, %{ops: ops}, action: :apply_projection_ops, authorize?: false)
  end

  defp apply_handler_ops(_, _row), do: :ok

  defp upsert_grain(resource, grain_key) when is_map(grain_key) do
    Ash.create!(resource, grain_key, action: :upsert_grain, authorize?: false)
  end

  defp upsert_grain(resource, grain_key) do
    [field] = resource.__projection_grain_fields__()
    Ash.create!(resource, %{field => grain_key}, action: :upsert_grain, authorize?: false)
  end
end
