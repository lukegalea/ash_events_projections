# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ProjectionResource do
  @moduledoc """
  Spark extension that injects the two actions every stats resource needs:

  - `:upsert_grain` — idempotent create-or-return keyed on `grain_fields`
  - `:apply_projection_ops` — accepts an `ops` list and applies all changes
    atomically via `AshEvents.Projections.ApplyOpsChange`

  Also exposes `__projection_grain_fields__/0` so the Server knows which
  attributes define the grain identity.

  Usage:

      use Ash.Resource,
        extensions: [AshEvents.Projections.ProjectionResource]

      projection_resource do
        grain_fields [:practice_id, :billing_period_start]
      end

  The stats resource must define an identity named `:by_grain` covering the
  same fields listed in `grain_fields`.
  """

  use Spark.Dsl.Extension,
    sections: [
      %Spark.Dsl.Section{
        name: :projection_resource,
        describe: "Configuration for projection stats resources.",
        schema: [
          grain_fields: [
            type: {:list, :atom},
            required: true,
            doc: "The attributes that uniquely identify each grain row (can be composite)."
          ]
        ]
      }
    ],
    transformers: [AshEvents.Projections.ProjectionResource.Transformer]
end
