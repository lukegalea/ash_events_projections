defmodule AshEvents.Projections.ProjectionResource.Transformer do
  @moduledoc false

  use Spark.Dsl.Transformer

  def transform(dsl) do
    grain_fields = resolve_grain_fields!(dsl)

    dsl
    |> inject_grain_field_function(grain_fields)
    |> inject_grain_identity(grain_fields)
    |> inject_upsert_grain_action(grain_fields)
    |> inject_apply_projection_ops_action()
    |> inject_truncate_function()
    |> wrap_ok()
  end

  defp wrap_ok({:ok, _} = result), do: result
  defp wrap_ok(dsl), do: {:ok, dsl}

  # `get_option(dsl, [:projection_resource], :grain_fields)` can be nil on some
  # Ash/Spark orderings; fall back to scanning dsl for the projection_resource
  # section opts. Never pass `accept: nil` into `add_action` — Ash's
  # `CacheActionInputs` does `Enum.concat(..., Map.get(action, :accept, []))`
  # which returns nil (not []) when the key exists with value nil, causing
  # Enumerable protocol errors on nil.
  defp resolve_grain_fields!(dsl) when is_map(dsl) do
    direct = Spark.Dsl.Transformer.get_option(dsl, [:projection_resource], :grain_fields)

    fields =
      if is_list(direct) and direct != [] do
        direct
      else
        dsl
        |> Enum.find_value(fn
          {path, %{opts: opts}} when is_list(path) ->
            case List.last(path) do
              :projection_resource -> Keyword.get(opts, :grain_fields)
              _ -> nil
            end

          _ ->
            nil
        end)
        |> List.wrap()
      end

    if fields == [] do
      raise Spark.Error.DslError,
        message:
          "ProjectionResource requires a non-empty `grain_fields` list inside " <>
            "`projection_resource do ... end` (e.g. `grain_fields [:practice_id]`).",
        path: [:projection_resource]
    else
      fields
    end
  end

  defp inject_grain_field_function(dsl, grain_fields) do
    Spark.Dsl.Transformer.eval(
      dsl,
      [],
      quote do
        def __projection_grain_fields__, do: unquote(grain_fields)
      end
    )
  end

  # Auto-derive the `:by_grain` identity from `grain_fields` so projection
  # resource modules do not need to repeat the `identities` block manually.
  # Emits a deprecation warning if the resource already defines `:by_grain`
  # explicitly so authors know they can remove it.
  defp inject_grain_identity(dsl, grain_fields) do
    if Ash.Resource.Info.identity(dsl, :by_grain) do
      IO.warn(
        "ProjectionResource: an explicit `identity :by_grain` block was found. " <>
          "The transformer now injects this identity automatically from `grain_fields`. " <>
          "Remove the `identities do ... end` block to suppress this warning.",
        []
      )

      {:ok, dsl}
    else
      Ash.Resource.Builder.add_identity(dsl, :by_grain, grain_fields)
    end
  end

  defp inject_upsert_grain_action(dsl, grain_fields) do
    Ash.Resource.Builder.add_action(dsl, :create, :upsert_grain,
      accept: grain_fields,
      upsert?: true,
      upsert_identity: :by_grain
    )
  end

  defp inject_apply_projection_ops_action(dsl) do
    # Update actions default `accept: nil` on the struct. `CacheActionInputs`
    # does `Enum.concat(..., Map.get(action, :accept, []))` — when the key is
    # present with value nil, `Map.get` returns nil and `Enum.concat` raises.
    # This action only accepts the `:ops` argument, not attributes.
    Ash.Resource.Builder.add_action(dsl, :update, :apply_projection_ops,
      accept: [],
      require_atomic?: false,
      arguments: [
        Ash.Resource.Builder.build_action_argument(:ops, :term,
          allow_nil?: false,
          description:
            "List of ops: {:increment, field, n}, {:decrement, field, n}, {:set, field, value}, {:max, field, value}"
        )
      ],
      changes: [
        Ash.Resource.Builder.build_action_change({AshEvents.Projections.ApplyOpsChange, []})
      ]
    )
  end

  # `truncate!/0` deletes every row in the projection table.  We use
  # `delete_all/1` rather than the TRUNCATE statement so the call participates
  # in the test sandbox transaction. Production rebuilds for stats tables on
  # the order of millions of rows are rare and still complete in seconds.
  defp inject_truncate_function({:ok, dsl}), do: inject_truncate_function(dsl)

  defp inject_truncate_function(dsl) do
    Spark.Dsl.Transformer.eval(
      dsl,
      [],
      quote do
        @doc """
        Deletes every row in the projection table.

        Used by `AshEvents.Projections.Rebuilder` to wipe stats before replay.
        """
        def truncate! do
          AshEvents.Projections.Config.repo().delete_all(__MODULE__)
          :ok
        end
      end
    )
  end
end
