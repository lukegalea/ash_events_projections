# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.Events.Event do
  @moduledoc false
  use Ash.Resource,
    domain: AshEvents.Projections.TestApp.Events,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  event_log do
    persist_actor_primary_key :user_id, AshEvents.Projections.TestApp.Accounts.User
    advisory_lock_key_generator(AshEvents.Projections.Events.RecordIdAdvisoryLockKeyGenerator)
  end

  attributes do
    attribute :practice_id, :uuid, public?: true
  end

  changes do
    change {AshEvents.Projections.Events.Changes.ExtractMetadataFields,
            fields: [
              {:practice_id, cast: :uuid},
              {:user_id, cast: :uuid, overwrite?: false}
            ]},
           on: [:create]

    change AshEvents.Projections.Events.Changes.NotifyProjectors, on: [:create]
  end

  postgres do
    table "ash_events"
    repo AshEvents.Projections.TestRepo
  end
end
