# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEventsProjections.Promote do
  @moduledoc """
  Promotes a caught-up shadow projector to serving, or rolls a promotion
  back.

      mix ash_events_projections.promote --projection=usage_v2 --live=usage_v1
      mix ash_events_projections.promote --projection=usage_v2 --live=usage_v1 --accept-differences
      mix ash_events_projections.promote --projection=usage_v1 --live=usage_v2 --rollback

  With `--rollback`, `--projection` is the retired projector to restore and
  `--live` the currently serving one. On refusal the differences (or the
  failing precondition) are printed and the task exits with an error; the
  registry is left untouched.
  """

  use Mix.Task

  alias AshEvents.Projections.Config
  alias AshEvents.Projections.Promotion

  @shortdoc "Promotes a shadow projection to serving, or rolls back"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          projection: :string,
          live: :string,
          "accept-differences": :boolean,
          rollback: :boolean
        ]
      )

    name = opts[:projection] || Mix.raise("--projection=<name> is required")
    live_name = opts[:live] || Mix.raise("--live=<name> is required")

    projector = find_projector!(name)
    live = find_projector!(live_name)

    if opts[:rollback] do
      Mix.shell().info("Rolling back to #{name}...")

      case Promotion.rollback(projector, live) do
        :ok -> Mix.shell().info("Rollback complete; #{name} is serving again.")
        {:error, reason} -> refuse(reason)
      end
    else
      Mix.shell().info("Promoting #{name} over #{live_name}...")

      case Promotion.promote(projector, live, accept_differences?: !!opts[:"accept-differences"]) do
        {:ok, comparison} ->
          Mix.shell().info(
            "Promotion complete: #{name} is serving (#{comparison.shadow_rows} rows), " <>
              "#{live_name} is retired."
          )

        {:error, reason} ->
          refuse(reason)
      end
    end
  end

  defp refuse({:differs_from_live, differences}) do
    Mix.shell().info("Refusing: the shadow differs from the live table:")

    Enum.each(differences, fn diff ->
      Mix.shell().info(
        "  #{inspect(diff.grain)} #{diff.field}: shadow=#{inspect(diff.shadow)} live=#{inspect(diff.live)}"
      )
    end)

    Mix.raise("shadow differs from live; pass --accept-differences to promote anyway")
  end

  defp refuse({:shadow_behind, shadow_last, log_last}) do
    Mix.shell().info(
      "Refusing: shadow checkpoint is at #{inspect(shadow_last)}, the event log at #{inspect(log_last)}."
    )

    Mix.raise("shadow is behind the event log")
  end

  defp refuse({:shadow_drift, drifts}) do
    Mix.shell().info("Refusing: the shadow does not match the event log:")

    Enum.each(drifts, fn drift ->
      Mix.shell().info("  #{inspect(drift)}")
    end)

    Mix.raise("shadow does not match the event log")
  end

  defp refuse({:unexpected_status, projection_name, status}) do
    Mix.shell().info("Refusing: #{projection_name} has registry status #{inspect(status)}.")
    Mix.raise("unexpected registry status for #{projection_name}")
  end

  defp refuse(other), do: Mix.raise("promotion refused: #{inspect(other)}")

  defp find_projector!(name) do
    Config.projectors()
    |> Enum.find(&(&1.__projector_name__() == name))
    |> case do
      nil -> Mix.raise("Unknown projection: #{name}")
      module -> module
    end
  end
end
