defmodule AshEvents.Projections.DeadLetter do
  @moduledoc """
  A poison-pill record for events that raised inside a projector handler.

  When `AshEvents.Projections.Server` traps an exception during `apply_event`,
  it inserts a row here (in its own transaction so it survives the surrounding
  rollback) and advances the checkpoint past the offending event. This keeps
  the projector flowing instead of being permanently blocked by a single bad
  event.

  ## Lifecycle

      :failed          — initial state; projector raised on this event
      :pending_replay  — operator (or `Operations.Dlq.replay/2`) marked it for retry
      :replayed        — successful replay; row kept for audit
      :purged          — operator decided the event is intentionally unprocessable

  See the operations how-to in `documentation/how-to/inspect-the-dlq.md`
  for the full operational workflow.
  """

  use AshEvents.Projections.InternalResource, table: "dead_letter_events"

  attributes do
    attribute :projection_name, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :event_id, :integer, primary_key?: true, allow_nil?: false, public?: true

    attribute :status, :atom,
      constraints: [one_of: [:failed, :pending_replay, :replayed, :purged]],
      default: :failed,
      allow_nil?: false,
      public?: true

    attribute :error_class, :string, allow_nil?: false, public?: true
    attribute :error_message, :string, allow_nil?: false, public?: true
    attribute :stacktrace, :string, allow_nil?: true, public?: true

    attribute :failed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :replayed_at, :utc_datetime_usec, allow_nil?: true, public?: true

    timestamps()
  end

  identities do
    identity :by_projection_and_event, [:projection_name, :event_id]
  end

  actions do
    defaults [:read]

    read :for_projection do
      argument :projection_name, :string, allow_nil?: false
      filter expr(projection_name == ^arg(:projection_name))
    end

    read :pending do
      filter expr(status == :failed or status == :pending_replay)
    end

    create :record_failure do
      upsert? true
      upsert_identity :by_projection_and_event

      accept [
        :projection_name,
        :event_id,
        :error_class,
        :error_message,
        :stacktrace,
        :failed_at
      ]

      change set_attribute(:status, :failed)
    end

    update :mark_pending_replay do
      change set_attribute(:status, :pending_replay)
    end

    update :mark_replayed do
      change set_attribute(:status, :replayed)
      change set_attribute(:replayed_at, &DateTime.utc_now/0)
    end

    update :mark_purged do
      change set_attribute(:status, :purged)
    end

    destroy :purge do
    end
  end

  code_interface do
    define :for_projection, args: [:projection_name]
    define :pending
    define :record_failure
    define :mark_pending_replay
    define :mark_replayed
    define :mark_purged
    define :purge
  end
end
