defmodule Mix.Tasks.AshEventsProjections.Gaps do
  @moduledoc """
  Reports gaps in `ash_events.id` (positions where the bigserial sequence
  skipped values).

      mix ash_events_projections.gaps
      mix ash_events_projections.gaps --since-id=10000

  Most gaps are benign rolled-back inserts. A run of large gaps that grow
  over time may indicate at-least-once delivery problems or manual deletes.

  See `backend/docs/runbooks/06-gap-detection.md`.
  """

  use Mix.Task

  alias AshEvents.Projections.Operations.Gaps

  @shortdoc "Reports gaps in the ash_events bigserial sequence"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [since_id: :integer])

    gaps = Gaps.detect(opts[:since_id])

    if gaps == [] do
      Mix.shell().info("No gaps detected.")
    else
      Mix.shell().info("Detected #{length(gaps)} gap(s):")

      Enum.each(gaps, fn g ->
        Mix.shell().info("  ids #{g.gap_start}..#{g.gap_end} (#{g.gap_size} missing)")
      end)

      Mix.shell().info("\nTotal missing ids: #{Enum.sum(Enum.map(gaps, & &1.gap_size))}")
    end
  end
end
