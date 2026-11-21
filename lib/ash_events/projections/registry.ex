# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Registry do
  @moduledoc """
  Per-projector lifecycle registry.

  Tracks two things that the in-memory `Server` GenServer cannot persist
  across crashes:

  - `status` — how the projector participates in draining:

    * `:active` — serving reads; the Server drains normally.
    * `:shadow` — building from the event log, not serving; the Server still
      drains (see `AshEvents.Projections.Promotion.build_shadow!/1`).
    * `:retired` — a former live projector kept up to date so rollback is
      instant; the Server still drains.
    * `:rebuilding` — an in-place rebuild is running; `Server.drain`
      short-circuits so a concurrent rebuild can truncate stats safely
      without races.

    Only `:rebuilding` short-circuits the drain.
  - `version` — counts how many times this row has been promoted to serving
    (`AshEvents.Projections.Promotion.promote/3` bumps it; a fresh row
    starts at 1).

  One row per projector. Initialized lazily by `Server.init/1` and the
  `Rebuilder`. Pair with `pg_advisory_xact_lock` keyed on `name` to serialize
  rebuild-style mutations across the cluster.
  """

  use AshEvents.Projections.InternalResource, table: "registry"

  attributes do
    attribute :name, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:active, :rebuilding, :shadow, :retired]],
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

    update :mark_shadow do
      change set_attribute(:status, :shadow)
    end

    update :mark_retired do
      change set_attribute(:status, :retired)
    end

    update :bump_version do
      change atomic_update(:version, expr(version + 1))
    end
  end

  code_interface do
    define :initialize, args: [:name]
    define :mark_rebuilding
    define :mark_active
    define :mark_shadow
    define :mark_retired
    define :bump_version
  end
end
