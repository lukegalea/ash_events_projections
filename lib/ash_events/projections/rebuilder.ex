# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Rebuilder do
  @moduledoc """
  Safely replays a projection from event 0 by:

  1. Acquiring a Postgres advisory lock keyed on the projector name so
     concurrent rebuilds across the cluster serialize on the same projector.
  2. Flipping the projector's `Registry` status to `:rebuilding` — the
     `Server.drain` loop short-circuits while this flag is set so no writes
     race with the truncate.
  3. Calling `Server.flush/1` to drain in-flight events; the in-flight drain
     finishes (committing whatever was already queued), then the next batch
     observes the rebuilding flag and returns early.
  4. Truncating the stats table.
  5. Resetting the checkpoint.
  6. Restoring the status captured in step 2 (`:active` for a live
     projector; `:shadow`/`:retired` rows keep their prior status).
  7. Notifying the Server to begin replay.

  We deliberately do NOT call `GenServer.stop/1` on the Server — that would
  trigger the `LeaderMonitor` re-election dance unnecessarily. The status
  flag is sufficient to keep the Server quiet during truncate.

  ## Concurrent rebuild safety

  The advisory lock prevents two `rebuild!/1` callers from interleaving truncate
  + reset steps. Other cluster nodes wait inside `pg_advisory_xact_lock`
  until the current rebuild commits.

  ## Side-by-side rebuilds

  To rebuild without stopping the live projector, build a shadow copy with a
  versioned name (`usage_v2`) and promote it atomically — see
  `AshEvents.Projections.Promotion` and
  `mix ash_events_projections.shadow`.
  """

  alias AshEvents.Projections.{Checkpoint, Registry, Server}
  alias AshEvents.Projections.Config

  require Logger

  @doc """
  Resets a projector's checkpoint and stats, then triggers a full replay.

  Returns `:ok` on success or `{:error, reason}` if any step fails.
  """
  @spec rebuild!(module()) :: :ok
  def rebuild!(projector_module) do
    name = projector_module.__projector_name__()

    Logger.info("[Projections.Rebuilder] starting rebuild for #{name}")

    # Assert the transaction commits AND that the inner code_interface calls
    # succeeded. Ecto returns {:ok, last_expression} on commit regardless of
    # whether the last expression is itself an :error tuple, so unwrap both
    # layers — otherwise a failed mark_rebuilding/1 would silently let the
    # Server keep draining while we truncate.
    {:ok, prior_status} =
      Config.repo().transaction(fn ->
        acquire_lock!(name)

        {:ok, _} = Registry.initialize(name)
        registry = Ash.get!(Registry, name, authorize?: false)
        prior_status = registry.status
        {:ok, _} = Registry.mark_rebuilding(registry)
        prior_status
      end)

    # Drain in-flight events so they finish committing under the OLD checkpoint
    # before we truncate. After this returns, future `drain` calls observe
    # `status: :rebuilding` and return :idle.
    Server.flush(name)

    projector_module.__projection_resource__().truncate!()

    case Ash.get(Checkpoint, name, authorize?: false) do
      {:ok, %Checkpoint{} = cp} -> Checkpoint.reset(cp)
      _ -> :ok
    end

    {:ok, registry} = Ash.get(Registry, name, authorize?: false)
    restore_status!(registry, prior_status)

    Server.notify(name)

    Logger.info("[Projections.Rebuilder] #{name} rebuild complete; replay started")

    :ok
  end

  # A rebuild must not promote a shadow or retired projector to serving: it
  # restores whatever status the row had before the rebuild flipped it to
  # :rebuilding.
  defp restore_status!(registry, :active), do: Registry.mark_active!(registry)
  defp restore_status!(registry, :shadow), do: Registry.mark_shadow!(registry)
  defp restore_status!(registry, :retired), do: Registry.mark_retired!(registry)
  defp restore_status!(registry, :rebuilding), do: Registry.mark_rebuilding!(registry)

  # Postgres advisory locks are scoped to the calling transaction; this is
  # safer than session-scoped locks because the lock is automatically released
  # if the connection drops mid-rebuild.  We hash the projector name into a
  # signed bigint so any name fits.
  defp acquire_lock!(name) do
    key = lock_key(name)
    Config.repo().query!("SELECT pg_advisory_xact_lock($1)", [key])
  end

  @doc false
  def lock_key(name) when is_binary(name) do
    <<int::signed-integer-64, _::binary>> = :crypto.hash(:sha256, name)
    int
  end
end
