# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.Accounts do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshEvents.Projections.TestApp.Accounts.User
    resource AshEvents.Projections.TestApp.Accounts.Member
  end
end

defmodule AshEvents.Projections.TestApp.Accounts.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Accounts,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  postgres do
    table "users"
    repo AshEvents.Projections.TestRepo
  end
end

defmodule AshEvents.Projections.TestApp.Accounts.Member do
  @moduledoc """
  Source resource with attached projection stats — exercises the
  `AshEvents.Projections.AttachProjection` extension end to end.
  """

  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.AttachProjection]

  projections do
    attach_projection AshEvents.Projections.TestApp.Projections.PracticeUsageStats,
                      AshEvents.Projections.TestApp.Projectors.Usage do
      field(:notes_used_this_period, :notes_count, :integer, default: 0)
      field(:care_cards_used_this_period, :care_cards_count, :integer, default: 0)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :practice_id, :uuid, public?: true
    attribute :billing_period_start, :date, public?: true
    timestamps()
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  postgres do
    table "members"
    repo AshEvents.Projections.TestRepo
  end
end
