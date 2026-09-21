defmodule AshEvents.Projections.Lag do
  @moduledoc """
  Computes per-projector lag against the event log head.

  Lag is exposed three ways:

    * `snapshot/0` — list of maps suitable for the
      `GET /health/projections` endpoint and Mix tasks.
    * `AshEvents.Projections.Probe` periodically calls `snapshot/0` and emits
      `[:ash_events_projections, :lag]` `:telemetry` events for AppSignal.
    * Each map includes `:leader_node` so split-brain or mid-election states
      are visible to operators (the `:global` registry may briefly point
      nowhere during failover).

  ## Snapshot shape

      %{
        name:         "practice_usage_v1",
        status:       :active,           # | :rebuilding (from Registry)
        leader_node:  :"node@host" | nil,
        last_seen_id: 12_345 | nil,
        head_id:      12_400 | nil,
        lag_events:   55,
        lag_seconds:  0.42,
        dlq_depth:    0
      }
  """

  alias AshEvents.Projections.{Checkpoint, Registry, Server}
  alias AshEvents.Projections.Config

  import Ecto.Query

  @doc """
  Returns one snapshot row per configured projector.

  Two Postgres round-trips per snapshot: one for the head id/timestamp and
  one COUNT per projector (accurate even when the bigserial sequence has
  gaps from rolled-back inserts — the bigserial max would over-estimate
  lag by every gap).
  """
  @spec snapshot() :: [map()]
  def snapshot do
    projectors = Config.projectors()
    head = head_id()
    head_at = head_occurred_at()

    Enum.map(projectors, &project_snapshot(&1, head, head_at))
  end

  @doc """
  Returns the snapshot row for a single projector by name.
  """
  @spec snapshot_for(String.t()) :: map() | nil
  def snapshot_for(name) when is_binary(name) do
    Config.projectors()
    |> Enum.find(&(&1.__projector_name__() == name))
    |> case do
      nil -> nil
      projector -> project_snapshot(projector, head_id(), head_occurred_at())
    end
  end

  @doc """
  Returns the maximum `lag_events` across all projectors. Useful for
  readiness gates.
  """
  @spec max_lag_events() :: non_neg_integer()
  def max_lag_events do
    snapshot()
    |> Enum.map(& &1.lag_events)
    |> Enum.max(fn -> 0 end)
  end

  defp project_snapshot(projector, head, head_at) do
    name = projector.__projector_name__()
    last_seen = checkpoint_last_seen(name)
    last_seen_at = occurred_at_for_id(last_seen)

    %{
      name: name,
      status: registry_status(name),
      leader_node: leader_node(name),
      last_seen_id: last_seen,
      head_id: head,
      lag_events: lag_events(last_seen),
      lag_seconds: lag_seconds(last_seen_at, head_at),
      dlq_depth: dlq_depth(name)
    }
  end

  defp head_id do
    Config.repo().one(from(e in Config.event_table(), select: max(e.id)))
  end

  defp head_occurred_at do
    Config.repo().one(from(e in Config.event_table(), select: max(e.occurred_at)))
  end

  defp checkpoint_last_seen(name) do
    case Ash.get(Checkpoint, name, authorize?: false) do
      {:ok, %{last_seen_event_id: id}} -> id
      _ -> nil
    end
  end

  defp occurred_at_for_id(nil), do: nil

  defp occurred_at_for_id(id) do
    Config.repo().one(
      from(e in Config.event_table(),
        where: e.id == ^id,
        select: e.occurred_at
      )
    )
  end

  defp registry_status(name) do
    case Ash.get(Registry, name, authorize?: false) do
      {:ok, %{status: status}} -> status
      _ -> :active
    end
  end

  defp leader_node(name) do
    case :global.whereis_name({Server, name}) do
      :undefined -> nil
      pid -> node(pid)
    end
  end

  # Counts the events the projector still has to process. Using COUNT(*) (vs.
  # `head_id - last_seen_id`) avoids over-counting bigserial gaps left by
  # rolled-back inserts — those gaps are NOT real backlog work.
  defp lag_events(nil) do
    Config.repo().one(from(e in Config.event_table(), select: count(e.id))) ||
      0
  end

  defp lag_events(last_seen) when is_integer(last_seen) do
    Config.repo().one(
      from(e in Config.event_table(),
        where: e.id > ^last_seen,
        select: count(e.id)
      )
    ) || 0
  end

  defp lag_seconds(nil, nil), do: 0.0
  defp lag_seconds(nil, _), do: 0.0
  defp lag_seconds(_, nil), do: 0.0

  defp lag_seconds(last_seen_at, head_at) do
    diff_us = NaiveDateTime.diff(head_at, last_seen_at, :microsecond)
    Float.round(max(diff_us, 0) / 1_000_000, 3)
  end

  defp dlq_depth(name) do
    Config.repo().one(
      from(d in "ash_projection_dead_letter_events",
        where: d.projection_name == ^name and d.status in ["failed", "pending_replay"],
        select: count(d.event_id)
      )
    ) || 0
  rescue
    _ -> 0
  end
end
