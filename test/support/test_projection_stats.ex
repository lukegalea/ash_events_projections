# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.Projections do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEvents.Projections.TestApp.Projections.PracticeUsageStats
    resource AshEvents.Projections.TestApp.Projections.PracticeUsageStatsV2
    resource AshEvents.Projections.TestApp.Projections.TenantUsageStats
    resource AshEvents.Projections.TestApp.Projections.UserLifetimeStats
    resource AshEvents.Projections.TestApp.Projections.DlqStats
  end
end

defmodule AshEvents.Projections.TestApp.Projections.PracticeUsageStats do
  @moduledoc """
  Composite-grain stats resource (practice + billing period) used by the
  stateless test projector and the AttachProjection tests.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:practice_id, :billing_period_start])
  end

  attributes do
    uuid_primary_key :id
    attribute :practice_id, :uuid, allow_nil?: false, public?: true
    attribute :billing_period_start, :date, allow_nil?: false, public?: true
    attribute :notes_count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :care_cards_count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :peak_notes, :integer, default: 0, allow_nil?: false, public?: true
    attribute :last_activity_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy]
  end

  postgres do
    table "test_practice_usage_stats"
    repo AshEvents.Projections.TestRepo
  end
end

defmodule AshEvents.Projections.TestApp.Projections.UserLifetimeStats do
  @moduledoc """
  Single-field-grain stats resource (user) used by the stateful (arity-2)
  test projector.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:user_id])
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :scores_count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :score_total, :integer, default: 0, allow_nil?: false, public?: true
    attribute :avg_score, :integer, default: 0, allow_nil?: false, public?: true
    attribute :top_score, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy]
  end

  postgres do
    table "test_user_lifetime_stats"
    repo AshEvents.Projections.TestRepo
  end
end

defmodule AshEvents.Projections.TestApp.Projections.PracticeUsageStatsV2 do
  @moduledoc """
  Shadow-table twin of `PracticeUsageStats` with identical grain fields and
  attributes — used by the `UsageV2` projector for promotion/blue-green tests
  and by `Verify.compare`.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:practice_id, :billing_period_start])
  end

  attributes do
    uuid_primary_key :id
    attribute :practice_id, :uuid, allow_nil?: false, public?: true
    attribute :billing_period_start, :date, allow_nil?: false, public?: true
    attribute :notes_count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :care_cards_count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :peak_notes, :integer, default: 0, allow_nil?: false, public?: true
    attribute :last_activity_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy]
  end

  postgres do
    table "test_practice_usage_stats_v2"
    repo AshEvents.Projections.TestRepo
  end
end

defmodule AshEvents.Projections.TestApp.Projections.TenantUsageStats do
  @moduledoc """
  Stats resource for the projector configured with
  `partition_column: :tenant_ref`. Single-field grain keyed by the tenant
  reference string.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:tenant_ref])
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_ref, :string, allow_nil?: false, public?: true
    attribute :notes_count, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy]
  end

  postgres do
    table "test_tenant_usage_stats"
    repo AshEvents.Projections.TestRepo
  end
end

defmodule AshEvents.Projections.TestApp.Projections.DlqStats do
  @moduledoc """
  Stats resource used by the deliberately-failing projector that feeds the
  dead-letter queue tests.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:practice_id])
  end

  attributes do
    uuid_primary_key :id
    attribute :practice_id, :uuid, allow_nil?: false, public?: true
    attribute :explosions_handled, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy]
  end

  postgres do
    table "test_dlq_stats"
    repo AshEvents.Projections.TestRepo
  end
end
