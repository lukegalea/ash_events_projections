# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEventsProjections.Rebuild do
  @moduledoc """
  Safely rebuilds a projection by truncating its stats table and replaying
  the full event log.

      mix ash_events_projections.rebuild --projection=practice_usage_v1

  Wraps `AshEvents.Projections.Rebuilder.rebuild!/1` which uses a Postgres
  advisory lock plus the `Registry.status` flag to ensure no writes race
  with the truncate.

  Use this after any handler-logic change. For purely additive new fields,
  see `mix ash_events_projections.bootstrap`.
  """

  use Mix.Task

  alias AshEvents.Projections.Config
  alias AshEvents.Projections.Rebuilder

  @shortdoc "Truncates a projection's stats and replays from event 0"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [projection: :string])

    name = opts[:projection] || Mix.raise("--projection=<name> is required")
    projector = find_projector!(name)

    Mix.shell().info("Rebuilding projection #{name}...")
    :ok = Rebuilder.rebuild!(projector)
    Mix.shell().info("Rebuild complete.")
  end

  defp find_projector!(name) do
    Config.projectors()
    |> Enum.find(&(&1.__projector_name__() == name))
    |> case do
      nil -> Mix.raise("Unknown projection: #{name}")
      module -> module
    end
  end
end
