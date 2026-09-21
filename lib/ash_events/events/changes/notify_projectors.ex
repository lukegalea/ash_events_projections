# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Events.Changes.NotifyProjectors do
  @moduledoc """
  Signals projection Servers after an event row is committed.

  Registers an `after_transaction` hook on the Event resource changeset.
  The hook fires only after the database transaction commits successfully,
  guaranteeing the event row is visible on other connections before any
  projector drains it. Rolled-back transactions produce no signal.

  On commit the hook broadcasts `{:event_committed, event_log_module}` to the
  `AshEvents.Projections.Config.pubsub()` topic configured by `AshEvents.Projections.Config.pubsub_topic/0`. Every node in
  the cluster runs a `AshEvents.Projections.PubSubListener` that subscribes to
  this topic and forwards the signal to the appropriate `Server` processes via
  `Server.notify/1`.

  Using Phoenix.PubSub instead of `pg_notify` avoids the extra persistent
  Postgres connection (and the DB load from LISTEN/NOTIFY) that was flagged
  as problematic in the team review.
  """

  use Ash.Resource.Change

  alias AshEvents.Projections.Config

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, event} ->
          Phoenix.PubSub.broadcast(
            Config.pubsub(),
            Config.pubsub_topic(),
            {:event_committed, event.__struct__}
          )

          result

        {:error, _} ->
          result
      end
    end)
  end
end
