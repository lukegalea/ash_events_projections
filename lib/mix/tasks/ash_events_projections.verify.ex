# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEventsProjections.Verify do
  @moduledoc """
  Recomputes every projector's stats from the raw event log and reports any
  drift against the live projection tables.

      mix ash_events_projections.verify
      mix ash_events_projections.verify --projection=practice_usage_v1

  Exits with status 1 if any drift is detected so CI can gate on it.

  Originally bisected the silent metadata-mismatch bug fixed in commit
  `5772b196` — keep running it after any change to source-resource events.
  """

  use Mix.Task

  alias AshEvents.Projections.Config
  alias AshEvents.Projections.Operations.Verify

  @shortdoc "Diffs each projection's stats vs a fresh recompute from events"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [projection: :string])

    results =
      case opts[:projection] do
        nil ->
          Verify.run_all()

        name ->
          [find_projector!(name) |> Verify.run()]
      end

    Enum.each(results, &print_result/1)

    drift_count =
      results
      |> Enum.flat_map(& &1.drifts)
      |> length()

    if drift_count > 0 do
      Mix.shell().error("\nDrift detected in #{drift_count} field(s). Exit code 1.")
      System.halt(1)
    else
      Mix.shell().info("\nAll projections in sync.")
    end
  end

  defp find_projector!(name) do
    Config.projectors()
    |> Enum.find(&(&1.__projector_name__() == name))
    |> case do
      nil -> Mix.raise("Unknown projection: #{name}")
      module -> module
    end
  end

  defp print_result(%{
         projection_name: name,
         checked_rows: checked,
         expected_rows: expected,
         drifts: []
       }) do
    Mix.shell().info("[OK] #{name}: #{checked} row(s) match (#{expected} expected)")
  end

  defp print_result(%{projection_name: name, drifts: drifts}) do
    Mix.shell().error("[DRIFT] #{name}: #{length(drifts)} drift(s)")

    Enum.each(drifts, fn d ->
      Mix.shell().error(
        "  grain=#{inspect(d.grain)} field=#{d.field} expected=#{inspect(d.expected)} actual=#{inspect(d.actual)}"
      )
    end)
  end
end
