defmodule Mix.Tasks.AshEventsProjections.Bootstrap do
  @moduledoc """
  Backfills a freshly-added projection from the historical event log.

      mix ash_events_projections.bootstrap --projection=user_lifetime_v1

  Resets the checkpoint so all events replay, then drains synchronously.

  For projections whose stats partially predate AshEvents (e.g. the
  `UserLifetimeStats` care_cards_count was retroactively populated from
  `note_artifacts` rows that existed before event logging was wired up),
  run the matching `priv/scripts/projections/prepopulate_*.sql` BEFORE the
  bootstrap. The bootstrap then layers post-event-log activity on top.

  Use `mix ash_events_projections.rebuild` instead when an existing projector's
  handler logic has changed — that path also truncates the stats table so
  increments do not double-count.
  """

  use Mix.Task

  alias AshEvents.Projections.Operations.Bootstrap

  @shortdoc "Replays the full event log into a (presumed empty) projection"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [projection: :string])

    name = opts[:projection] || Mix.raise("--projection=<name> is required")
    projector = find_projector!(name)

    Mix.shell().info("Bootstrapping #{name}...")
    :ok = Bootstrap.run!(projector)
    Mix.shell().info("Bootstrap complete.")
  end

  defp find_projector!(name) do
    AshEvents.Projections.Config.projectors()
    |> Enum.find(&(&1.__projector_name__() == name))
    |> case do
      nil -> Mix.raise("Unknown projection: #{name}")
      module -> module
    end
  end
end
