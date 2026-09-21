# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ServerTest do
  use AshEvents.Projections.ProjectionCase, async: false

  require Ash.Query

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.Registry
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats
  alias AshEvents.Projections.TestApp.Projections.UserLifetimeStats

  setup do
    practice_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, practice_id: practice_id, user_id: user_id}
  end

  describe "drain happy path" do
    test "builds grain rows from pending events", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})
      refute stats_for(practice_id)

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      :ok = Server.flush(Usage.__projector_name__())

      row = stats_for(practice_id)
      assert %PracticeUsageStats{} = row
      assert row.notes_count == 1
      assert row.billing_period_start == ~D[2026-09-01]
    end

    test "aggregates multiple events for the same grain", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      for _ <- 1..3 do
        log_event!(
          action: :note_created,
          practice_id: practice_id,
          metadata: %{"billing_period_start" => "2026-09-01"}
        )
      end

      log_event!(
        action: :care_card_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      :ok = Server.flush(Usage.__projector_name__())

      row = stats_for(practice_id)
      assert row.notes_count == 3
      assert row.care_cards_count == 1
    end

    test "splits grains by billing period", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-10-01"}
      )

      :ok = Server.flush(Usage.__projector_name__())

      assert [first, second] = all_stats(practice_id)
      assert first.notes_count == 1
      assert second.notes_count == 1

      assert Enum.map([first, second], & &1.billing_period_start) |> Enum.sort() ==
               [~D[2026-09-01], ~D[2026-10-01]]
    end

    test "ignores events with no matching handler", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      log_event!(action: :something_else, practice_id: practice_id)
      :ok = Server.flush(Usage.__projector_name__())

      refute stats_for(practice_id)
    end

    test "skips events whose grain resolves to nil", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      # note_created would match a handler, but the metadata lacks a billing
      # period, so grain/1 returns nil and the event is not folded.
      log_event!(action: :note_created, practice_id: practice_id)
      log_event!(action: :ignored_action, practice_id: practice_id)
      :ok = Server.flush(Usage.__projector_name__())

      refute stats_for(practice_id)
    end

    test "applies decrement, set, and max ops", %{practice_id: practice_id, user_id: user_id} do
      start_supervised!({Server, Usage})

      metadata = %{"billing_period_start" => "2026-09-01"}

      log_event!(action: :note_created, practice_id: practice_id, metadata: metadata)
      log_event!(action: :note_created, practice_id: practice_id, metadata: metadata)
      log_event!(action: :note_deleted, practice_id: practice_id, metadata: metadata)

      closed =
        log_event!(
          action: :session_closed,
          practice_id: practice_id,
          metadata: metadata,
          user_id: user_id
        )

      log_event!(
        action: :peak_reached,
        practice_id: practice_id,
        metadata: metadata,
        data: %{"count" => 7}
      )

      :ok = Server.flush(Usage.__projector_name__())

      row = stats_for(practice_id)
      assert row.notes_count == 1
      assert row.last_activity_at == closed.occurred_at
      assert row.peak_notes == 7
    end

    test "stateful projector folds events into the current row", %{user_id: user_id} do
      start_supervised!({Server, UserLifetime})

      log_event!(action: :score_recorded, user_id: user_id, data: %{"score" => 2})
      log_event!(action: :score_recorded, user_id: user_id, data: %{"score" => 5})

      :ok = Server.flush(UserLifetime.__projector_name__())

      row = lifetime_stats_for(user_id)
      assert row.scores_count == 2
      assert row.score_total == 7
      assert row.avg_score == 3
      assert row.top_score == 5
    end
  end

  describe "checkpointing" do
    test "advances the checkpoint atomically with the ops", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      events =
        for _ <- 1..2 do
          log_event!(
            action: :note_created,
            practice_id: practice_id,
            metadata: %{"billing_period_start" => "2026-09-01"}
          )
        end

      :ok = Server.flush(Usage.__projector_name__())

      checkpoint = Ash.get!(Checkpoint, Usage.__projector_name__(), authorize?: false)
      assert checkpoint.last_seen_event_id == List.last(events).id
      assert checkpoint.events_processed == 2
    end

    test "flush is idempotent — no double counting", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      :ok = Server.flush(Usage.__projector_name__())
      :ok = Server.flush(Usage.__projector_name__())

      assert stats_for(practice_id).notes_count == 1
    end
  end

  describe "rebuild gating" do
    test "skips the drain while the registry says :rebuilding", %{practice_id: practice_id} do
      name = Usage.__projector_name__()
      Registry.initialize!(name)
      Registry.mark_rebuilding!(Ash.get!(Registry, name, authorize?: false))

      # Event exists and registry is :rebuilding before the server boots, so
      # the boot drain deterministically hits the skip path.
      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      start_supervised!({Server, Usage})
      :ok = Server.flush(name)
      refute stats_for(practice_id)

      Registry.mark_active!(Ash.get!(Registry, name, authorize?: false))
      :ok = Server.flush(name)
      assert stats_for(practice_id).notes_count == 1
    end
  end

  defp stats_for(practice_id) do
    Ash.read_one!(
      PracticeUsageStats
      |> Ash.Query.filter(practice_id == ^practice_id),
      authorize?: false
    )
  end

  defp all_stats(practice_id) do
    PracticeUsageStats
    |> Ash.Query.filter(practice_id == ^practice_id)
    |> Ash.read!(authorize?: false)
  end

  defp lifetime_stats_for(user_id) do
    Ash.read_one!(UserLifetimeStats |> Ash.Query.filter(user_id == ^user_id), authorize?: false)
  end
end
