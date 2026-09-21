# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TimeTravelTest do
  use AshEvents.Projections.DataCase, async: true

  alias AshEvents.Projections.TestApp.Projectors.Usage
  alias AshEvents.Projections.TestApp.Projectors.UserLifetime
  alias AshEvents.Projections.TimeTravel

  import AshEvents.Projections.TestApp.EventFactory

  @t1 ~N[2026-09-01 10:00:00]
  @t2 ~N[2026-09-01 11:00:00]
  @t3 ~N[2026-09-01 12:00:00]

  setup do
    user_id = Ecto.UUID.generate()
    {:ok, user_id: user_id}
  end

  describe "state_at/3 on a stateful projector" do
    test "replays every event at or before the timestamp", %{user_id: user_id} do
      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 2},
        occurred_at: @t1
      )

      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 5},
        occurred_at: @t2
      )

      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 3},
        occurred_at: @t3
      )

      assert %{scores_count: 2, score_total: 7, avg_score: 3, top_score: 5} =
               TimeTravel.state_at(UserLifetime, %{user_id: user_id}, @t2)
    end

    test "excludes events after the timestamp", %{user_id: user_id} do
      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 2},
        occurred_at: @t2
      )

      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 5},
        occurred_at: @t3
      )

      state = TimeTravel.state_at(UserLifetime, %{user_id: user_id}, @t1)

      assert state == %{}
    end

    test "filters to the requested grain", %{user_id: user_id} do
      other = Ecto.UUID.generate()

      log_event!(action: :score_recorded, user_id: other, data: %{"score" => 9}, occurred_at: @t1)

      log_event!(
        action: :score_recorded,
        user_id: user_id,
        data: %{"score" => 2},
        occurred_at: @t1
      )

      assert %{scores_count: 1, score_total: 2, top_score: 2} =
               TimeTravel.state_at(UserLifetime, %{user_id: user_id}, @t3)
    end
  end

  describe "state_at/3 on the stateless projector" do
    test "folds increment and decrement ops in event order", %{user_id: user_id} do
      practice_id = Ecto.UUID.generate()
      metadata = %{"billing_period_start" => "2026-09-01"}

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: metadata,
        occurred_at: @t1
      )

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: metadata,
        occurred_at: @t2
      )

      log_event!(
        action: :note_deleted,
        practice_id: practice_id,
        metadata: metadata,
        occurred_at: @t3
      )

      grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}

      assert %{notes_count: 2} = TimeTravel.state_at(Usage, grain, @t2)
      assert %{notes_count: 1} = TimeTravel.state_at(Usage, grain, @t3)
    end

    test "folds :max monotonically across events", %{user_id: user_id} do
      practice_id = Ecto.UUID.generate()
      metadata = %{"billing_period_start" => "2026-09-01"}

      log_event!(
        action: :peak_reached,
        practice_id: practice_id,
        metadata: metadata,
        data: %{"count" => 3},
        occurred_at: @t1
      )

      log_event!(
        action: :peak_reached,
        practice_id: practice_id,
        metadata: metadata,
        data: %{"count" => 7},
        occurred_at: @t2
      )

      log_event!(
        action: :peak_reached,
        practice_id: practice_id,
        metadata: metadata,
        data: %{"count" => 5},
        occurred_at: @t3
      )

      grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}

      assert %{peak_notes: 3} = TimeTravel.state_at(Usage, grain, @t1)
      assert %{peak_notes: 7} = TimeTravel.state_at(Usage, grain, @t2)
      assert %{peak_notes: 7} = TimeTravel.state_at(Usage, grain, @t3)
    end

    test "folds :set as last write wins", %{user_id: user_id} do
      practice_id = Ecto.UUID.generate()
      metadata = %{"billing_period_start" => "2026-09-01"}

      log_event!(
        action: :session_closed,
        practice_id: practice_id,
        metadata: metadata,
        occurred_at: @t1
      )

      log_event!(
        action: :session_closed,
        practice_id: practice_id,
        metadata: metadata,
        occurred_at: @t2
      )

      grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}

      at_t1 = TimeTravel.state_at(Usage, grain, @t1)
      at_t2 = TimeTravel.state_at(Usage, grain, @t2)

      assert at_t1.last_activity_at == ~N[2026-09-01 10:00:00.000000]
      assert at_t2.last_activity_at == ~N[2026-09-01 11:00:00.000000]
    end

    test "skips events whose grain resolves to nil" do
      practice_id = Ecto.UUID.generate()

      # Matches the :note_created handler but carries no billing period, so
      # the Usage projector's grain fn returns nil.
      log_event!(action: :note_created, practice_id: practice_id, occurred_at: @t1)

      assert TimeTravel.state_at(
               Usage,
               %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]},
               @t3
             ) == %{}
    end
  end

  test "accepts both DateTime and NaiveDateTime timestamps", %{user_id: user_id} do
    log_event!(action: :score_recorded, user_id: user_id, data: %{"score" => 2}, occurred_at: @t2)

    from_naive = TimeTravel.state_at(UserLifetime, %{user_id: user_id}, @t2)

    from_datetime =
      TimeTravel.state_at(
        UserLifetime,
        %{user_id: user_id},
        DateTime.from_naive!(@t2, "Etc/UTC")
      )

    assert from_naive == from_datetime
  end
end
