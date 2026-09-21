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
  6. Flipping status back to `:active`.
  7. Notifying the Server to begin replay.

  We deliberately do NOT call `GenServer.stop/1` on the Server — that would
  trigger the `LeaderMonitor` re-election dance unnecessarily. The status
  flag is sufficient to keep the Server quiet during truncate.

  ## Concurrent rebuild safety

  The advisory lock prevents two `rebuild!/1` callers from interleaving truncate
  + reset steps. Other cluster nodes wait inside `pg_advisory_xact_lock`
  until the current rebuild commits.

  ## Versioned (blue/green) rebuilds

  Pass a different `projector_module` whose `__projector_name__/0` returns a
  new version (e.g. `usage_v2`) and whose `__projection_resource__/0` points
  at a shadow table. The two projectors run side-by-side; flip your reads to
  the new one when ready.

  See `backend/docs/runbooks/02-in-place-rebuild.md` and
  `backend/docs/runbooks/03-blue-green-rebuild.md` for the full operational
  procedures.
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
    {:ok, :ok} =
      Config.repo().transaction(fn ->
        acquire_lock!(name)

        {:ok, _} = Registry.initialize(name)
        registry = Ash.get!(Registry, name, authorize?: false)
        {:ok, _} = Registry.mark_rebuilding(registry)
        :ok
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
    Registry.mark_active(registry)

    Server.notify(name)

    Logger.info("[Projections.Rebuilder] #{name} rebuild complete; replay started")

    :ok
  end

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
