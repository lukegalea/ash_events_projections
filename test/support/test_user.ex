defmodule AshEvents.Projections.TestApp.Accounts do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshEvents.Projections.TestApp.Accounts.User
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
