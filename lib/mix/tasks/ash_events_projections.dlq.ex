defmodule Mix.Tasks.AshEventsProjections.Dlq do
  @moduledoc """
  Inspect, replay, or purge dead-letter rows for a projector.

      mix ash_events_projections.dlq inspect --projection=user_lifetime_v1
      mix ash_events_projections.dlq replay  --projection=user_lifetime_v1
      mix ash_events_projections.dlq replay  --projection=user_lifetime_v1 --event-ids=1234,5678
      mix ash_events_projections.dlq purge   --projection=user_lifetime_v1
      mix ash_events_projections.dlq purge   --projection=user_lifetime_v1 --hard-delete

  ## Replay semantics

  Replay re-runs the offending events through the live projector in their
  own transactions WITHOUT rolling back the global checkpoint, so events
  that succeeded after the original failure are not double-counted.

  See `backend/docs/runbooks/05-dlq-inspect-and-replay.md`.
  """

  use Mix.Task

  alias AshEvents.Projections.Operations.Dlq

  @shortdoc "Inspect / replay / purge dead-letter rows for a projector"
  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [projection: :string, event_ids: :string, hard_delete: :boolean]
      )

    projection = opts[:projection] || Mix.raise("--projection=<name> is required")
    [subcommand | _] = positional |> Enum.reject(&is_nil/1) |> Enum.concat(["inspect"])

    case subcommand do
      "inspect" -> do_inspect(projection)
      "replay" -> do_replay(projection, opts)
      "purge" -> do_purge(projection, opts)
      other -> Mix.raise("Unknown subcommand: #{other}. Use inspect | replay | purge.")
    end
  end

  defp do_inspect(name) do
    rows = Dlq.list(name)

    if rows == [] do
      Mix.shell().info("DLQ for #{name} is empty.")
    else
      Mix.shell().info("DLQ for #{name}:")

      Enum.each(rows, fn r ->
        Mix.shell().info(
          "  event_id=#{r.event_id} status=#{r.status} class=#{r.error_class} failed_at=#{r.failed_at}"
        )

        Mix.shell().info("    #{r.error_message}")
      end)

      Mix.shell().info("\nTotal: #{length(rows)} row(s)")
    end
  end

  defp do_replay(name, opts) do
    projector = find_projector!(name)
    event_ids = parse_ids(opts[:event_ids])

    replay_opts = if event_ids, do: [event_ids: event_ids], else: []
    result = Dlq.replay(projector, replay_opts)

    Mix.shell().info(
      "Replay complete: replayed=#{result.replayed} failed=#{result.failed} skipped=#{result.skipped}"
    )

    if result.failed > 0, do: System.halt(1)
  end

  defp do_purge(name, opts) do
    n = Dlq.purge(name, hard_delete?: !!opts[:hard_delete])
    verb = if opts[:hard_delete], do: "hard-deleted", else: "marked :purged"
    Mix.shell().info("#{verb} #{n} row(s).")
  end

  defp parse_ids(nil), do: nil

  defp parse_ids(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
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
