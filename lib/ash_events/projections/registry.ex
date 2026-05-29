defmodule AshEvents.Projections.Registry do
  @moduledoc """
  Per-projector lifecycle registry.

  Tracks two things that the in-memory `Server` GenServer cannot persist
  across crashes:

  - `status` (`:active` or `:rebuilding`) — `Server.drain` checks this
    before applying ops; while `:rebuilding`, the Server short-circuits so
    a concurrent rebuild can truncate stats safely without races.
  - `version` — integer that lets blue/green rebuilds run a shadow
    projector with a separate `projection_name` (e.g. `usage_v1` /
    `usage_v2`) without colliding on grain rows.

  One row per projector. Initialized lazily by `Server.init/1` and the
  `Rebuilder`. Pair with `pg_advisory_xact_lock` keyed on `name` to serialize
  rebuild-style mutations across the cluster.
  """

  use AshEvents.Projections.InternalResource, table: "registry"

  attributes do
    attribute :name, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:active, :rebuilding]],
      default: :active,
      allow_nil?: false,
      public?: true

    attribute :version, :integer, default: 1, allow_nil?: false, public?: true

    timestamps()
  end

  identities do
    identity :by_name, [:name]
  end

  actions do
    defaults [:read]

    create :initialize do
      upsert? true
      upsert_identity :by_name
      upsert_fields []

      accept [:name]
    end

    update :mark_rebuilding do
      change set_attribute(:status, :rebuilding)
    end

    update :mark_active do
      change set_attribute(:status, :active)
    end

    update :bump_version do
      change atomic_update(:version, expr(version + 1))
    end
  end

  code_interface do
    define :initialize, args: [:name]
    define :mark_rebuilding
    define :mark_active
    define :bump_version
  end
end
