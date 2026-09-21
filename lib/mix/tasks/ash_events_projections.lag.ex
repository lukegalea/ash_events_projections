# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshEventsProjections.Lag do
  @moduledoc """
  Reports current lag, status, leader node, and DLQ depth for every
  configured projector.

      mix ash_events_projections.lag

  Same data the `GET /health/projections` endpoint exposes — see
  `backend/docs/runbooks/08-observability-lag-and-health.md`.
  """

  use Mix.Task

  alias AshEvents.Projections.Lag

  @shortdoc "Reports projection lag and DLQ depth"
  @requirements ["app.start"]

  @impl true
  def run(_args) do
    rows = Lag.snapshot()

    if rows == [] do
      Mix.shell().info("No projectors configured.")
    else
      Mix.shell().info(
        Enum.join(
          [
            String.pad_trailing("name", 28),
            String.pad_trailing("status", 12),
            String.pad_trailing("leader", 25),
            String.pad_leading("checkpoint", 12),
            String.pad_leading("head", 12),
            String.pad_leading("lag_ev", 8),
            String.pad_leading("lag_s", 8),
            String.pad_leading("dlq", 6)
          ],
          " "
        )
      )

      Enum.each(rows, &print_row/1)
    end
  end

  defp print_row(row) do
    Mix.shell().info(
      Enum.join(
        [
          String.pad_trailing(row.name, 28),
          String.pad_trailing(to_string(row.status), 12),
          String.pad_trailing(to_string(row.leader_node || "none"), 25),
          String.pad_leading(to_string(row.last_seen_id || "0"), 12),
          String.pad_leading(to_string(row.head_id || "0"), 12),
          String.pad_leading(to_string(row.lag_events), 8),
          String.pad_leading(:erlang.float_to_binary(row.lag_seconds, decimals: 2), 8),
          String.pad_leading(to_string(row.dlq_depth), 6)
        ],
        " "
      )
    )
  end
end
