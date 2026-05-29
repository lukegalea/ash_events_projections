defmodule AshEvents.Projections.TimeTravel do
  @moduledoc """
  Reconstructs the projection state for a single grain at any past point in
  time by replaying every event that occurred at or before the requested
  timestamp.

  Powers `mix ash_events_projections.lag` ad-hoc debugging and the
  "what was this counter on date X?" workflow described in
  `backend/docs/runbooks/07-temporal-queries.md`.

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

  alias AshEvents.Projections.Config

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

    target_key = normalize_key(grain_key)

    AshEvents.Projections.Config.event_table()
    |> select_columns()
    |> where_before(timestamp)
    |> Config.repo().all()
    |> Enum.map(&normalize/1)
    |> Enum.filter(fn event ->
      case grain_fn.(event) do
        nil -> false
        key -> normalize_key(key) == target_key
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
      {:max, f, v}, s -> Map.update(s, f, v, fn cur -> if(cur >= v, do: cur, else: v) end)
    end)
  end

  defp normalize_key(key) when is_map(key), do: key

  defp select_columns(table) do
    from(e in table,
      select: %{
        id: e.id,
        practice_id: e.practice_id,
        user_id: e.user_id,
        occurred_at: e.occurred_at,
        metadata: e.metadata,
        resource: e.resource,
        action: e.action,
        action_type: e.action_type
      },
      order_by: [asc: e.id]
    )
  end

  defp where_before(query, timestamp) do
    from(e in query, where: e.occurred_at <= ^timestamp)
  end

  defp normalize(row) do
    %{
      id: row.id,
      practice_id: uuid_to_string(row.practice_id),
      user_id: uuid_to_string(row.user_id),
      occurred_at: row.occurred_at,
      metadata: row.metadata || %{},
      resource: to_atom(row.resource),
      action: to_atom(row.action),
      action_type: to_atom(row.action_type)
    }
  end

  defp uuid_to_string(nil), do: nil

  defp uuid_to_string(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    {:ok, s} = Ecto.UUID.load(uuid)
    s
  end

  defp uuid_to_string(uuid), do: uuid

  defp to_atom(s) when is_binary(s), do: String.to_atom(s)
  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(nil), do: nil
end
