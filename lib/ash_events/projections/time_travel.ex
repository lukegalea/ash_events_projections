# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TimeTravel do
  @moduledoc """
  Reconstructs the projection state for a single grain at any past point in
  time by replaying every event that occurred at or before the requested
  timestamp.

  Powers `mix ash_events_projections.lag` ad-hoc debugging and the
  "what was this counter on date X?" workflow.

  Costs O(events-up-to-timestamp) so don't use this on hot paths — it is a
  diagnostic tool, not an alternative to the live projection table.

  ## Example

      iex> alias AshEvents.Projections.TimeTravel
      iex> TimeTravel.state_at(
      ...>   AshEvents.Projections.Lifetime.UserLifetimeProjector,
      ...>   %{user_id: user_id},
      ...>   ~U[2026-04-01 00:00:00Z]
      ...> )
      %{care_cards_count: 7, client_emails_sent_count: 1, ...}
  """

  alias AshEvents.Projections.{Config, EventRow}

  import Ecto.Query

  @doc """
  Returns the projection state for a single grain at `timestamp`.

  Replays every event that:
    1. Occurs at or before `timestamp`.
    2. Maps to the requested `grain_key` via the projector's grain function.

  Returns a map of `field => value` (counters default to 0 for any field the
  events touched). Returns `%{}` if no matching events exist.
  """
  @spec state_at(module(), map(), DateTime.t() | NaiveDateTime.t()) :: map()
  def state_at(projector_module, grain_key, %DateTime{} = timestamp) do
    state_at(projector_module, grain_key, DateTime.to_naive(timestamp))
  end

  def state_at(projector_module, grain_key, %NaiveDateTime{} = timestamp) do
    grain_fn = projector_module.__grain__()
    grain_fields = projector_module.__projection_resource__().__projection_grain_fields__()
    partition_column = projector_module.__partition_column__()

    target_key = normalize_key(grain_key, grain_fields)

    Config.event_table()
    |> EventRow.query(partition_column)
    |> where_before(timestamp)
    |> Config.repo().all()
    |> Enum.map(&EventRow.normalize(&1, partition_column))
    |> Enum.filter(fn event ->
      case grain_fn.(event) do
        nil -> false
        key -> normalize_key(key, grain_fields) == target_key
      end
    end)
    |> Enum.reduce(%{}, fn event, acc ->
      ops = ops_for(projector_module, event, acc)
      apply_ops(acc, ops)
    end)
  end

  defp ops_for(projector_module, event, current) do
    if projector_module.needs_current_state?(event) do
      case projector_module.handle_event(event, current) do
        {:ok, ops} -> ops
        :skip -> []
      end
    else
      case projector_module.handle_event(event) do
        {:ok, ops} -> ops
        :skip -> []
      end
    end
  rescue
    _ -> []
  end

  defp apply_ops(state, ops) do
    Enum.reduce(ops, state, fn
      {:increment, f, n}, s -> Map.update(s, f, n, &(&1 + n))
      {:decrement, f, n}, s -> Map.update(s, f, -n, &(&1 - n))
      {:set, f, v}, s -> Map.put(s, f, v)
      {:max, f, v}, s -> Map.update(s, f, v, &max_value(&1, v))
    end)
  end

  defp max_value(current, v), do: if(current >= v, do: current, else: v)

  # Map grains are compared as-is; scalar grains (single-field projections)
  # are wrapped in a one-field map so both the requested and the event-derived
  # key land in the same shape. Mirrors Verify.grain_key_for_acc/2.
  defp normalize_key(key, _) when is_map(key), do: key

  defp normalize_key(scalar, [field]), do: %{field => scalar}

  defp where_before(query, timestamp) do
    from(e in query, where: e.occurred_at <= ^timestamp)
  end
end
