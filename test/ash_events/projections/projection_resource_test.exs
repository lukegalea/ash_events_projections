# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ProjectionResourceTest do
  use AshEvents.Projections.DataCase, async: true

  require Ash.Query

  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats

  @grain %{practice_id: nil, billing_period_start: ~D[2026-09-01]}

  setup do
    {:ok, practice_id: Ecto.UUID.generate()}
  end

  test "exposes the configured grain fields" do
    assert PracticeUsageStats.__projection_grain_fields__() == [
             :practice_id,
             :billing_period_start
           ]
  end

  test "upsert_grain creates the row for a new grain", %{practice_id: practice_id} do
    row = upsert_grain!(practice_id)

    assert %PracticeUsageStats{} = row
    assert row.practice_id == practice_id
    assert row.billing_period_start == ~D[2026-09-01]
    assert row.notes_count == 0
  end

  test "upsert_grain is idempotent per grain", %{practice_id: practice_id} do
    first = upsert_grain!(practice_id)
    second = upsert_grain!(practice_id)

    assert first.id == second.id

    assert length(rows(practice_id)) == 1
  end

  test "distinct grains get distinct rows", %{practice_id: practice_id} do
    other = Ecto.UUID.generate()

    upsert_grain!(practice_id)
    upsert_grain!(other)

    assert length(rows(practice_id)) == 1
    assert length(rows(other)) == 1
  end

  test "apply_projection_ops increments accumulate", %{practice_id: practice_id} do
    row = upsert_grain!(practice_id)

    row =
      Ash.update!(row, %{ops: [{:increment, :notes_count, 2}]},
        action: :apply_projection_ops,
        authorize?: false
      )

    row =
      Ash.update!(row, %{ops: [{:increment, :notes_count, 3}]},
        action: :apply_projection_ops,
        authorize?: false
      )

    assert row.notes_count == 5
  end

  test "apply_projection_ops supports decrement, set, and max", %{practice_id: practice_id} do
    row =
      upsert_grain!(practice_id)
      |> Ash.update!(
        %{
          ops: [
            {:increment, :notes_count, 3},
            {:decrement, :notes_count, 1},
            {:max, :peak_notes, 7},
            {:max, :peak_notes, 5},
            {:set, :last_activity_at, ~U[2026-09-01 08:30:00.000000Z]}
          ]
        },
        action: :apply_projection_ops,
        authorize?: false
      )

    assert row.notes_count == 2
    assert row.peak_notes == 7
    assert row.last_activity_at == ~U[2026-09-01 08:30:00.000000Z]
  end

  test "apply_projection_ops with an empty op list changes nothing", %{practice_id: practice_id} do
    row =
      upsert_grain!(practice_id)
      |> Ash.update!(%{ops: []}, action: :apply_projection_ops, authorize?: false)

    assert row.notes_count == 0
  end

  test "truncate!/0 removes every projection row", %{practice_id: practice_id} do
    upsert_grain!(practice_id)
    upsert_grain!(Ecto.UUID.generate())

    :ok = PracticeUsageStats.truncate!()

    assert PracticeUsageStats |> Ash.read!(authorize?: false) == []
  end

  defp upsert_grain!(practice_id) do
    PracticeUsageStats
    |> Ash.Changeset.for_create(:upsert_grain, %{@grain | practice_id: practice_id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp rows(practice_id) do
    PracticeUsageStats
    |> Ash.Query.filter(practice_id == ^practice_id)
    |> Ash.read!(authorize?: false)
  end
end
