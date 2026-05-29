defmodule Mix.Tasks.AshEventsProjections.EventGrowth do
  @moduledoc """
  Reports per-day event count and approximate payload size for the last
  N days (default 30), plus all-time totals.

      mix ash_events_projections.event_growth
      mix ash_events_projections.event_growth --days=90

  See `backend/docs/runbooks/12-storage-growth.md`.
  """

  use Mix.Task

  alias AshEvents.Projections.Operations.EventGrowth

  @shortdoc "Daily event-log growth + all-time totals"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [days: :integer])
    days = opts[:days] || 30

    Mix.shell().info("Event-log growth (last #{days} day(s)):")
    Mix.shell().info("  day        events    payload")

    EventGrowth.by_day(days)
    |> Enum.each(fn r ->
      Mix.shell().info(
        "  #{r.day}  #{String.pad_leading(to_string(r.events_written), 8)}  " <>
          format_bytes(r.payload_bytes)
      )
    end)

    totals = EventGrowth.totals()

    Mix.shell().info(
      "\nAll-time: #{totals.events} event(s), payload #{format_bytes(totals.payload_bytes)}"
    )
  end

  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b) when b < 1024 * 1024 * 1024, do: "#{Float.round(b / 1024 / 1024, 1)} MB"
  defp format_bytes(b), do: "#{Float.round(b / 1024 / 1024 / 1024, 1)} GB"
end
