# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEventsProjections.Shadow do
  @moduledoc """
  Starts building a shadow projector from event 0 while the live projector
  of the same family keeps serving.

      mix ash_events_projections.shadow --projection=usage_v2

  Wraps `AshEvents.Projections.Promotion.build_shadow!/1`, which marks the
  projector `:shadow` in the registry; its Server drains from event 0 into
  its own projection table without serving reads. Watch it catch up with
  `mix ash_events_projections.lag`, compare it with
  `mix ash_events_projections.verify`, then promote it with
  `mix ash_events_projections.promote`.
  """

  use Mix.Task

  alias AshEvents.Projections.Config
  alias AshEvents.Projections.Promotion

  @shortdoc "Marks a projector :shadow and builds it from event 0"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [projection: :string])

    name = opts[:projection] || Mix.raise("--projection=<name> is required")
    projector = find_projector!(name)

    Mix.shell().info("Building shadow projection #{name}...")
    :ok = Promotion.build_shadow!(projector)

    Mix.shell().info(
      "Shadow #{name} is building; check catch-up with mix ash_events_projections.lag."
    )
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
