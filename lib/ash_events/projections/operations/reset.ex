defmodule AshEvents.Projections.Operations.Reset do
  @moduledoc """
  Resets a projector's checkpoint without truncating its stats table.

  Use sparingly — replaying without a truncate causes increment-style ops
  to double-count. The "right" action in most cases is `Rebuilder.rebuild!/1`,
  which truncates first. Reset is here for the one edge case it does
  cleanly: when the events have NOT been processed yet (e.g. you want to
  force a freshly-deployed projector to re-walk from event 0 because some
  earlier events were ingested while the projector was misconfigured).

  See `backend/docs/runbooks/11-reset-checkpoint.md`.
  """

  alias AshEvents.Projections.{Checkpoint, Server}

  require Logger

  @spec run!(String.t()) :: :ok
  def run!(projector_name) when is_binary(projector_name) do
    {:ok, _} = Checkpoint.initialize(projector_name)
    cp = Ash.get!(Checkpoint, projector_name, authorize?: false)
    Checkpoint.reset(cp)
    Server.notify(projector_name)

    Logger.warning(
      "[Projections.Reset] checkpoint reset for #{projector_name} — " <>
        "increment counters MAY now double-count if stats rows already exist"
    )

    :ok
  end
end
