# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.VerifyTest do
  use AshEvents.Projections.DataCase, async: false

  require Ash.Query

  alias AshEvents.Projections.Operations.Verify
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats
  alias AshEvents.Projections.TestApp.Projections.UserLifetimeStats
  alias AshEvents.Projections.TestApp.Projectors.Usage
  alias AshEvents.Projections.TestApp.Projectors.UserLifetime

  import AshEvents.Projections.TestApp.EventFactory

  @period "2026-09-01"

  setup do
    practice_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, practice_id: practice_id, user_id: user_id}
  end

  test "reports no drift when the projection matches the event log", %{practice_id: practice_id} do
    for _ <- 1..2 do
      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => @period}
      )
    end

    grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}

    PracticeUsageStats
    |> Ash.Changeset.for_create(:upsert_grain, grain, authorize?: false)
    |> Ash.create!(authorize?: false)
    |> Ash.update!(%{ops: [{:increment, :notes_count, 2}]},
      action: :apply_projection_ops,
      authorize?: false
    )

    result = Verify.run(Usage, flush: false)

    assert result.projection_name == Usage.__projector_name__()
    assert result.checked_rows == 1
    assert result.expected_rows == 1
    assert result.drifts == []
  end

  test "detects a missing projection row", %{practice_id: practice_id} do
    log_event!(
      action: :note_created,
      practice_id: practice_id,
      metadata: %{"billing_period_start" => @period}
    )

    result = Verify.run(Usage, flush: false)

    assert result.expected_rows == 1
    assert result.checked_rows == 0

    assert [%{field: :__row__, expected: :present, actual: :missing, grain: grain}] =
             result.drifts

    assert grain.practice_id == practice_id
    assert grain.billing_period_start == ~D[2026-09-01]
  end

  test "detects field-level drift with expected and actual values", %{practice_id: practice_id} do
    log_event!(
      action: :note_created,
      practice_id: practice_id,
      metadata: %{"billing_period_start" => @period}
    )

    grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}

    PracticeUsageStats
    |> Ash.Changeset.for_create(:upsert_grain, grain, authorize?: false)
    |> Ash.create!(authorize?: false)
    |> Ash.update!(%{ops: [{:increment, :notes_count, 99}]},
      action: :apply_projection_ops,
      authorize?: false
    )

    result = Verify.run(Usage, flush: false)

    assert [%{field: :notes_count, expected: 1, actual: 99}] = result.drifts
  end

  test "detects extra rows that have no backing events", %{practice_id: practice_id} do
    ghost_practice = Ecto.UUID.generate()

    PracticeUsageStats
    |> Ash.Changeset.for_create(:upsert_grain, %{
      practice_id: ghost_practice,
      billing_period_start: ~D[2026-09-01]
    })
    |> Ash.create!(authorize?: false)
    |> Ash.update!(%{ops: [{:increment, :notes_count, 5}]},
      action: :apply_projection_ops,
      authorize?: false
    )

    result = Verify.run(Usage, flush: false)

    assert result.checked_rows == 1
    assert result.expected_rows == 0
    assert [%{field: :__row__, expected: :missing, actual: :present}] = result.drifts
  end

  test "ignores extra rows whose counters are all zero", %{practice_id: practice_id} do
    PracticeUsageStats
    |> Ash.Changeset.for_create(:upsert_grain, %{
      practice_id: Ecto.UUID.generate(),
      billing_period_start: ~D[2026-09-01]
    })
    |> Ash.create!(authorize?: false)

    result = Verify.run(Usage, flush: false)

    assert result.drifts == []
  end

  test "folds stateful handlers against in-memory state", %{user_id: user_id} do
    log_event!(action: :score_recorded, user_id: user_id, data: %{"score" => 2})
    log_event!(action: :score_recorded, user_id: user_id, data: %{"score" => 5})

    UserLifetimeStats
    |> Ash.Changeset.for_create(:upsert_grain, %{user_id: user_id}, authorize?: false)
    |> Ash.create!(authorize?: false)
    |> Ash.update!(
      %{
        ops: [
          {:increment, :scores_count, 2},
          {:increment, :score_total, 7},
          {:set, :avg_score, 3},
          {:max, :top_score, 5}
        ]
      },
      action: :apply_projection_ops,
      authorize?: false
    )

    result = Verify.run(UserLifetime, flush: false)
    assert result.drifts == []
  end

  test "run_all/1 verifies every configured projector" do
    Application.put_env(:ash_events_projections, :projectors, [Usage, UserLifetime])
    on_exit(fn -> Application.delete_env(:ash_events_projections, :projectors) end)

    results = Verify.run_all(flush: false)
    names = Enum.map(results, & &1.projection_name)

    assert names == [Usage.__projector_name__(), UserLifetime.__projector_name__()]
    assert Enum.all?(results, &(&1.drifts == []))
  after
    Application.delete_env(:ash_events_projections, :projectors)
  end

  test "flush: true is the default and drains before verifying" do
    # Without a running server, Server.flush/1 is a no-op that must not raise.
    assert %{drifts: []} = Verify.run(Usage)
  end
end
