defmodule AshEvents.Projections.AttachProjection do
  @moduledoc """
  Spark DSL extension that attaches pre-aggregated projection stats to any
  Ash resource, exposing stats table fields as first-class calculations.

  ## Usage on a source resource

      use Ash.Resource,
        extensions: [AshEvents.Projections.AttachProjection]

      attach_projection AshEvents.Projections.Usage.PracticeUsageStats,
        via: AshEvents.Projections.Usage.PracticeUsageProjector do
        field :notes_used_this_period,        :unique_notes_count,  :integer, default: 0
        field :dental_exams_used_this_period, :dental_exams_count,  :integer, default: 0
        field :care_cards_used_this_period,   :care_cards_count,    :integer, default: 0
      end

  The `via:` projector module must implement:
  - `current_grain_for_record(record)` — returns the grain key map (or nil to
    return the default), computed from a fully-loaded source record
  - `preload_for_grain()` — returns the load list that the calculation's
    `load/3` callback will request so that `current_grain_for_record/1` has
    the data it needs

  For each `field` declaration the transformer injects a `calculate` into
  the source resource backed by `AshEvents.Projections.AttachProjection.Calc`.
  The calculation is a point-lookup into the stats table keyed by the grain.
  """

  defmodule Field do
    @moduledoc false
    defstruct [:name, :stats_field, :type, :__spark_metadata__, default: 0]
  end

  defmodule Config do
    @moduledoc false
    defstruct [:stats_resource, :via, :__spark_metadata__, fields: []]
  end

  @field_entity %Spark.Dsl.Entity{
    name: :field,
    describe: "Expose a stats-table column as a calculated field on the source resource.",
    args: [:name, :stats_field, :type],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the calculated field on the source resource."
      ],
      stats_field: [
        type: :atom,
        required: true,
        doc: "The column name in the stats resource to read."
      ],
      type: [
        type: :any,
        default: :integer,
        doc: "The Ash type for the calculation (e.g. :integer, :float, :string)."
      ],
      default: [
        type: :any,
        default: 0,
        doc: "Value returned when no stats row exists for the current grain."
      ]
    ],
    target: Field
  }

  @attach_projection_entity %Spark.Dsl.Entity{
    name: :attach_projection,
    describe: "Attach one stats resource to this resource, exposing its fields as calculations.",
    args: [:stats_resource, :via],
    schema: [
      stats_resource: [
        type: :atom,
        required: true,
        doc: "The Ash resource that stores the pre-aggregated stats."
      ],
      via: [
        type: :atom,
        required: true,
        doc: "The projector module that knows how to compute the grain for a source record."
      ]
    ],
    entities: [fields: [@field_entity]],
    target: Config
  }

  @projections_section %Spark.Dsl.Section{
    name: :projections,
    describe: "Projection stats attachments for this resource.",
    entities: [@attach_projection_entity]
  }

  use Spark.Dsl.Extension,
    sections: [@projections_section],
    transformers: [AshEvents.Projections.AttachProjection.Transformer]
end

defmodule AshEvents.Projections.AttachProjection.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    attachments = Transformer.get_entities(dsl, [:projections])

    Enum.reduce_while(attachments, {:ok, dsl}, fn attachment, {:ok, acc_dsl} ->
      case inject_calculations(acc_dsl, attachment) do
        {:ok, new_dsl} -> {:cont, {:ok, new_dsl}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp inject_calculations(dsl, %{stats_resource: stats_resource, via: projector, fields: fields}) do
    Enum.reduce_while(fields, {:ok, dsl}, fn field, {:ok, acc_dsl} ->
      opts = [
        stats_resource: stats_resource,
        stats_field: field.stats_field,
        projector: projector,
        default: field.default
      ]

      case Builder.add_calculation(
             acc_dsl,
             field.name,
             field.type,
             {AshEvents.Projections.AttachProjection.Calc, opts},
             public?: true
           ) do
        {:ok, new_dsl} -> {:cont, {:ok, new_dsl}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end

defmodule AshEvents.Projections.AttachProjection.Calc do
  @moduledoc """
  Shared `Ash.Resource.Calculation` used by every `attach_projection` field.

  Opts (set by the transformer, not by callers):
  - `:stats_resource` — the Ash stats resource to query
  - `:stats_field`    — the attribute on the stats resource to return
  - `:projector`      — module implementing `current_grain_for_record/1` and
                        `preload_for_grain/0`
  - `:default`        — value when no stats row exists (default: 0)
  """

  use Ash.Resource.Calculation
  require Ash.Query

  @impl true
  def load(_query, opts, _context) do
    Keyword.fetch!(opts, :projector).preload_for_grain()
  end

  @impl true
  def calculate(records, opts, _context) do
    projector = Keyword.fetch!(opts, :projector)
    stats_resource = Keyword.fetch!(opts, :stats_resource)
    stats_field = Keyword.fetch!(opts, :stats_field)
    default = Keyword.get(opts, :default, 0)

    Enum.map(records, fn record ->
      lookup_stats(projector, stats_resource, record)
      |> case do
        nil -> default
        stats -> Map.get(stats, stats_field) || default
      end
    end)
  end

  # Point-lookup into the stats table keyed by the record's grain. Returns nil
  # when the grain cannot be resolved or no stats row exists.
  defp lookup_stats(projector, stats_resource, record) do
    case projector.current_grain_for_record(record) do
      nil -> nil
      grain_key -> read_stats_row(stats_resource, grain_key)
    end
  end

  defp read_stats_row(stats_resource, grain_key) do
    grain_key
    |> Enum.reduce(stats_resource, fn {field, value}, query ->
      Ash.Query.filter(query, ^[{field, value}])
    end)
    |> Ash.read_one!(authorize?: false)
  end
end
