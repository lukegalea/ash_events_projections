# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.AttachProjectionTest do
  use AshEvents.Projections.ProjectionCase, async: false

  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Accounts.Member

  import AshEvents.Projections.TestApp.EventFactory

  setup do
    member =
      Member
      |> Ash.Changeset.for_create(:create, %{
        practice_id: Ecto.UUID.generate(),
        billing_period_start: ~D[2026-09-01]
      })
      |> Ash.create!(authorize?: false)

    {:ok, member: member}
  end

  test "attached calculations default to 0 when no stats row exists", %{member: member} do
    loaded =
      Ash.load!(member, [:notes_used_this_period, :care_cards_used_this_period],
        authorize?: false
      )

    assert loaded.notes_used_this_period == 0
    assert loaded.care_cards_used_this_period == 0
  end

  test "attached calculations resolve projected stats for the record's grain", %{
    member: member
  } do
    start_supervised!({Server, Usage})

    metadata = %{"billing_period_start" => "2026-09-01"}

    for _ <- 1..2 do
      log_event!(action: :note_created, practice_id: member.practice_id, metadata: metadata)
    end

    log_event!(action: :care_card_created, practice_id: member.practice_id, metadata: metadata)

    :ok = Server.flush(Usage.__projector_name__())

    loaded =
      Ash.load!(member, [:notes_used_this_period, :care_cards_used_this_period],
        authorize?: false
      )

    assert loaded.notes_used_this_period == 2
    assert loaded.care_cards_used_this_period == 1
  end

  test "a member outside the projected grain still gets the default", %{member: member} do
    start_supervised!({Server, Usage})

    log_event!(
      action: :note_created,
      practice_id: Ecto.UUID.generate(),
      metadata: %{"billing_period_start" => "2026-09-01"}
    )

    :ok = Server.flush(Usage.__projector_name__())

    loaded = Ash.load!(member, [:notes_used_this_period], authorize?: false)
    assert loaded.notes_used_this_period == 0
  end

  test "a member with an unresolvable grain gets the default" do
    member =
      Member
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.create!(authorize?: false)

    loaded = Ash.load!(member, [:notes_used_this_period], authorize?: false)
    assert loaded.notes_used_this_period == 0
  end
end
