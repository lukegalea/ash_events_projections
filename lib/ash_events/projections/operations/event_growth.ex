defmodule AshEvents.Projections.Operations.EventGrowth do
  @moduledoc """
  Reports per-day event-log growth and approximate payload size.

  Pure read-only probe. Use as a periodic (weekly) operational signal —
  unbounded growth here means archival/retention work is overdue.

  See `backend/docs/runbooks/12-storage-growth.md`.
  """

  alias AshEvents.Projections.Config

  @type day_row :: %{
          day: Date.t(),
          events_written: integer(),
          payload_bytes: integer()
        }

  @doc """
  Returns one row per day for the last `days` days (default 30).
  """
  @spec by_day(integer()) :: [day_row()]
  def by_day(days \\ 30) when is_integer(days) and days > 0 do
    sql = """
    SELECT
      DATE_TRUNC('day', occurred_at)::date AS day,
      COUNT(*)                             AS events_written,
      COALESCE(SUM(
        OCTET_LENGTH(COALESCE(metadata::text, '')) +
        OCTET_LENGTH(COALESCE(data::text, '')) +
        OCTET_LENGTH(COALESCE(changed_attributes::text, ''))
      ), 0)                                AS payload_bytes
    FROM ash_events
    WHERE occurred_at > now() - ($1 || ' days')::interval
    GROUP BY 1
    ORDER BY 1 DESC
    """

    Config.repo().query!(sql, [Integer.to_string(days)]).rows
    |> Enum.map(fn [day, events_written, payload_bytes] ->
      %{day: day, events_written: events_written, payload_bytes: payload_bytes || 0}
    end)
  end

  @doc """
  Returns total events and total payload bytes across the entire `ash_events`
  table.
  """
  @spec totals() :: %{events: integer(), payload_bytes: integer()}
  def totals do
    sql = """
    SELECT
      COUNT(*),
      COALESCE(SUM(
        OCTET_LENGTH(COALESCE(metadata::text, '')) +
        OCTET_LENGTH(COALESCE(data::text, '')) +
        OCTET_LENGTH(COALESCE(changed_attributes::text, ''))
      ), 0)
    FROM ash_events
    """

    [[count, payload_bytes]] = Config.repo().query!(sql, []).rows
    %{events: count, payload_bytes: payload_bytes || 0}
  end
end
