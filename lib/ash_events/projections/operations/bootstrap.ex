defmodule AshEvents.Projections.Operations.Bootstrap do
  @moduledoc """
  Backfills a freshly-added projection from the historical event log.

  Use when:

    * A new projector is being deployed for the first time. AshEvents only
      emits going forward, so any rows that should derive from pre-event-log
      data must be seeded from the source tables (see
      `priv/scripts/projections/prepopulate_*.sql`).
    * An existing projector gains new fields (e.g. the
      `UserLifetimeStats` ToS-timestamp expansion in commit `2c925d23`).
      Replay the full event history into the expanded shape, then optionally
      run a SQL prepopulate for fields that pre-date the event log.

  The operation:

    1. Resets the checkpoint to 0 so all events replay.
    2. Calls `Server.flush/1` to drain everything synchronously.

  Stats rows are left in place — increment-style ops are not idempotent under
  a partial replay. Pair with `Rebuilder.rebuild!/1` if you need a clean
  slate; this operation is for "additive" backfills like a brand-new
  projection or a brand-new field on an existing one.

  See `backend/docs/runbooks/01-bootstrap-new-projection.md`.
  """

  alias AshEvents.Projections.{Checkpoint, Server}

  require Logger

  @spec run!(module()) :: :ok
  def run!(projector_module) do
    name = projector_module.__projector_name__()
    Logger.info("[Projections.Bootstrap] starting backfill for #{name}")

    {:ok, _} = Checkpoint.initialize(name)
    cp = Ash.get!(Checkpoint, name, authorize?: false)
    Checkpoint.reset(cp)

    Server.notify(name)
    Server.flush(name)

    Logger.info("[Projections.Bootstrap] #{name} backfill complete")
    :ok
  end
end
