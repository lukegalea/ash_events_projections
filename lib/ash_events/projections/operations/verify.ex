defmodule AshEvents.Projections.Operations.Verify do
  @moduledoc """
  Recomputes each projector's stats from the raw event log and diffs against
  the live projection tables.

  The verifier replays every event the projector handles in a single pass,
  accumulating counters and timestamps in-memory using the projector's own
  `grain/1` function and `handle_event/1,2` clauses. The resulting "expected"
  shape is then compared row-by-row against the projection table.

  ## Why this exists

  Catches the silent-drift class of bug where real events arrive with
  different metadata than the projector's tests expect. The
  `NoteArtifact.create_empty` regression fixed in commit `5772b196` is the
  flagship example — synthetic factory events worked fine while production
  events hit an empty `metadata` map and were silently skipped. A regular
  verify run flags the discrepancy in seconds.

  See `backend/docs/runbooks/09-verify-projection-completeness.md`.
  """

  alias AshEvents.Projections.{Config, Server}

  import Ecto.Query

  @type drift :: %{
          projection_name: String.t(),
          grain: map(),
          field: atom(),
          expected: term(),
          actual: term()
        }

  @type result :: %{
          projection_name: String.t(),
          checked_rows: non_neg_integer(),
          expected_rows: non_neg_integer(),
          drifts: [drift()]
        }

  @doc """
  Verifies one projector. Returns `%{projection_name, checked_rows, expected_rows, drifts}`.

  Options:

    * `:flush` — when `true` (default), calls `Server.flush/1` first to ensure
      the projector has processed every committed event before snapshotting.
  """
  @spec run(module(), keyword()) :: result()
  def run(projector_module, opts \\ []) do
    name = projector_module.__projector_name__()
    if Keyword.get(opts, :flush, true), do: Server.flush(name)

    expected = recompute(projector_module)
    actual = load_projection_rows(projector_module)

    drifts = diff(name, expected, actual)

    %{
      projection_name: name,
      checked_rows: map_size(actual),
      expected_rows: map_size(expected),
      drifts: drifts
    }
  end

  @doc """
  Verifies every configured projector and returns one result per projector.
  """
  @spec run_all(keyword()) :: [result()]
  def run_all(opts \\ []) do
    Config.projectors()
    |> Enum.map(&run(&1, opts))
  end

  # --- Recompute ---

  defp recompute(projector_module) do
    grain_fn = projector_module.__grain__()
    grain_fields = projector_module.__projection_resource__().__projection_grain_fields__()

    Config.event_table()
    |> select_all_event_columns()
    |> Config.repo().all()
    |> Enum.map(&normalize/1)
    |> Enum.reduce(%{}, fn event, acc ->
      fold_event(projector_module, grain_fn, grain_fields, event, acc)
    end)
  end

  defp fold_event(projector_module, grain_fn, grain_fields, event, acc) do
    case grain_fn.(event) do
      nil -> acc
      grain_key -> fold_grain(projector_module, grain_key, grain_fields, event, acc)
    end
  end

  defp fold_grain(projector_module, grain_key, grain_fields, event, acc) do
    key = grain_key_for_acc(grain_key, grain_fields)
    current = Map.get(acc, key, %{})

    case ops_for_event(projector_module, event, current) do
      :skip -> acc
      ops -> Map.put(acc, key, apply_ops(current, ops))
    end
  end

  defp ops_for_event(projector_module, event, current) do
    if projector_module.needs_current_state?(event) do
      case projector_module.handle_event(event, current) do
        {:ok, ops} -> ops
        :skip -> :skip
      end
    else
      case projector_module.handle_event(event) do
        {:ok, ops} -> ops
        :skip -> :skip
      end
    end
  rescue
    _ -> :skip
  end

  defp apply_ops(current, ops) do
    Enum.reduce(ops, current, fn
      {:increment, field, n}, acc -> Map.update(acc, field, n, &(&1 + n))
      {:decrement, field, n}, acc -> Map.update(acc, field, -n, &(&1 - n))
      {:set, field, value}, acc -> Map.put(acc, field, value)
      {:max, field, value}, acc -> Map.update(acc, field, value, &maxv(&1, value))
    end)
  end

  defp maxv(nil, b), do: b
  defp maxv(a, nil), do: a
  defp maxv(a, b), do: if(a >= b, do: a, else: b)

  defp grain_key_for_acc(grain_key, _) when is_map(grain_key), do: grain_key

  defp grain_key_for_acc(scalar, [field]), do: %{field => scalar}

  # --- Compare ---

  defp load_projection_rows(projector_module) do
    resource = projector_module.__projection_resource__()
    grain_fields = resource.__projection_grain_fields__()

    resource
    |> Ash.read!(authorize?: false)
    |> Map.new(fn row ->
      key = Map.new(grain_fields, fn f -> {f, Map.get(row, f)} end)
      {key, row}
    end)
  end

  defp diff(name, expected, actual) do
    fields_to_compare = collect_fields(expected)

    drifts_in_expected =
      Enum.flat_map(expected, fn {grain, expected_row} ->
        diff_grain(name, grain, expected_row, actual, fields_to_compare)
      end)

    drifts_extra =
      for {grain, _row} <- actual,
          not Map.has_key?(expected, grain),
          actual_row = Map.get(actual, grain),
          has_nonzero_counter?(actual_row, fields_to_compare) do
        %{
          projection_name: name,
          grain: grain,
          field: :__row__,
          expected: :missing,
          actual: :present
        }
      end

    drifts_in_expected ++ drifts_extra
  end

  defp diff_grain(name, grain, expected_row, actual, fields_to_compare) do
    case Map.get(actual, grain) do
      nil -> [missing_row_drift(name, grain)]
      actual_row -> field_drifts(name, grain, expected_row, actual_row, fields_to_compare)
    end
  end

  defp missing_row_drift(name, grain) do
    %{
      projection_name: name,
      grain: grain,
      field: :__row__,
      expected: :present,
      actual: :missing
    }
  end

  defp field_drifts(name, grain, expected_row, actual_row, fields_to_compare) do
    for field <- fields_to_compare,
        exp = Map.get(expected_row, field, default_for(field)),
        act = Map.get(actual_row, field, default_for(field)),
        exp != act do
      %{
        projection_name: name,
        grain: grain,
        field: field,
        expected: exp,
        actual: act
      }
    end
  end

  defp collect_fields(expected) do
    expected
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
  end

  defp default_for(field) do
    if Atom.to_string(field) =~ ~r/_count$/, do: 0, else: nil
  end

  defp has_nonzero_counter?(row, fields) do
    Enum.any?(fields, fn f ->
      v = Map.get(row, f)
      is_integer(v) && v != 0
    end)
  end

  # --- Event loading ---

  defp select_all_event_columns(table) do
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

  # Use to_existing_atom/1 — see AshEvents.Projections.Server.to_atom/1.
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(nil), do: nil
end
