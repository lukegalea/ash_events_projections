defmodule Mix.Tasks.AshEventsProjections.Reset do
  @moduledoc """
  Resets a projector's checkpoint to 0 WITHOUT truncating its stats.

      mix ash_events_projections.reset --projection=user_lifetime_v1

  WARNING: increment-style ops (e.g. `:increment :care_cards_count`) will
  double-count if the stats rows are not also empty. In almost every case
  you actually want `mix ash_events_projections.rebuild`, which truncates
  first.

  See `backend/docs/runbooks/11-reset-checkpoint.md` for the exact decision
  matrix.
  """

  use Mix.Task

  alias AshEvents.Projections.Operations.Reset

  @shortdoc "Resets a projector's checkpoint (use rebuild instead in most cases)"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [projection: :string])
    name = opts[:projection] || Mix.raise("--projection=<name> is required")

    Mix.shell().info("Resetting checkpoint for #{name}...")
    :ok = Reset.run!(name)
    Mix.shell().info("Done. Re-drain triggered.")
  end
end
