# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.PubSubListenerTest do
  use AshEvents.Projections.ProjectionCase, async: false

  alias AshEvents.Projections.Config
  alias AshEvents.Projections.PubSubListener
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Accounts.User
  alias AshEvents.Projections.TestApp.Events.Event
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats

  import AshEvents.Projections.TestApp.EventFactory

  test "a commit broadcast wakes the projector and the event gets drained" do
    start_supervised!({Server, Usage})
    listener = start_supervised!({PubSubListener, []})

    log_event!(
      action: :note_created,
      practice_id: Ecto.UUID.generate(),
      metadata: %{"billing_period_start" => "2026-09-01"}
    )

    :ok =
      Phoenix.PubSub.broadcast(Config.pubsub(), Config.pubsub_topic(), {:event_committed, Event})

    # Sync on the listener so its handle_info has run before we assert.
    assert %{} = :sys.get_state(listener)

    :ok = Server.flush(Usage.__projector_name__())

    counts =
      PracticeUsageStats
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.notes_count)

    assert counts == [1]
  end

  test "broadcasts for other event logs are ignored" do
    listener = start_supervised!({PubSubListener, []})

    :ok =
      Phoenix.PubSub.broadcast(Config.pubsub(), Config.pubsub_topic(), {:event_committed, User})

    assert %{} = :sys.get_state(listener)
  end

  test "notifications without a running server are harmless" do
    listener = start_supervised!({PubSubListener, []})

    assert Server.notify(Usage.__projector_name__()) == :ok

    :ok =
      Phoenix.PubSub.broadcast(Config.pubsub(), Config.pubsub_topic(), {:event_committed, Event})

    assert %{} = :sys.get_state(listener)
  end
end
