defmodule AshEvents.Projections.Checkpoint do
  @moduledoc """
  Tracks how far each projector has processed the event log.

  One row per projector (keyed by `projection_name`). The `last_seen_event_id`
  is a bigint matching the `ash_events.id` bigserial primary key. Advancing
  the checkpoint atomically prevents double-processing even if a projector
  process restarts mid-drain.
  """

  use AshEvents.Projections.InternalResource, table: "checkpoints"

  attributes do
    attribute :projection_name, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :last_seen_event_id, :integer, allow_nil?: true, public?: true
    attribute :events_processed, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  identities do
    identity :by_name, [:projection_name]
  end

  actions do
    read :read do
      primary? true
    end

    create :initialize do
      upsert? true
      upsert_identity :by_name
      upsert_fields []

      accept [:projection_name]
    end

    update :advance do
      argument :event_id, :integer, allow_nil?: false
      change set_attribute(:last_seen_event_id, arg(:event_id))
      change atomic_update(:events_processed, expr(events_processed + 1))
    end

    update :reset do
      change set_attribute(:last_seen_event_id, nil)
      change set_attribute(:events_processed, 0)
    end
  end

  code_interface do
    define :read
    define :initialize, args: [:projection_name]
    define :advance, args: [:event_id]
    define :reset
  end
end
