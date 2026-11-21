# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.PromotionTest do
  use AshEvents.Projections.ProjectionCase, async: false

  require Ash.Query

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.Operations.Verify
  alias AshEvents.Projections.Promotion
  alias AshEvents.Projections.Rebuilder
  alias AshEvents.Projections.Registry
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStatsV2
  alias AshEvents.Projections.TestApp.Projectors.Usage
  alias AshEvents.Projections.TestApp.Projectors.UsageV2
  alias AshEvents.Projections.TestApp.Projectors.UserLifetime

  @period "2026-09-01"

  setup do
    practice_id = Ecto.UUID.generate()
    {:ok, practice_id: practice_id}
  end

  describe "family/1" do
    test "strips a trailing _v<digits> suffix" do
      assert Promotion.family("usage_v2") == "usage"
      assert Promotion.family("usage_v10") == "usage"
      assert Promotion.family("usage") == "usage"
      assert Promotion.family(Usage) == "test_practice_usage"
      assert Promotion.family(UsageV2) == "test_practice_usage"
      assert Promotion.family(UserLifetime) == "test_user_lifetime"
    end
  end

  describe "build_shadow!/1" do
    test "marks the projector :shadow without touching the live one", %{
      practice_id: practice_id
    } do
      Registry.initialize!(Usage.__projector_name__())

      :ok = Promotion.build_shadow!(UsageV2)

      assert registry_status(UsageV2.__projector_name__()) == :shadow
      assert registry_status(Usage.__projector_name__()) == :active
    end

    test "a Server.init upsert leaves a :shadow row alone" do
      :ok = Promotion.build_shadow!(UsageV2)

      start_server!(UsageV2)
      :ok = Server.flush(UsageV2.__projector_name__())

      assert registry_status(UsageV2.__projector_name__()) == :shadow
    end

    test "raises for the family's serving projector" do
      Registry.initialize!(Usage.__projector_name__())

      assert_raise ArgumentError, ~r/serving projector/, fn ->
        Promotion.build_shadow!(Usage)
      end
    end
  end

  describe "promote/3 happy path" do
    test "shadow builds from event 0 while live keeps serving", %{practice_id: practice_id} do
      start_server!(Usage)

      log_two_notes!(practice_id)
      :ok = Server.flush(Usage.__projector_name__())
      assert practice_row!(PracticeUsageStats, practice_id).notes_count == 2

      :ok = Promotion.build_shadow!(UsageV2)

      start_server!(UsageV2)
      :ok = Server.flush(UsageV2.__projector_name__())

      assert practice_row!(PracticeUsageStatsV2, practice_id).notes_count == 2
      assert registry_status(UsageV2.__projector_name__()) == :shadow
      assert registry_status(Usage.__projector_name__()) == :active
    end

    test "compare/3 of identical logic returns no differences", %{practice_id: practice_id} do
      build_both!(practice_id)

      comparison = Verify.compare(UsageV2, Usage, flush: false)

      assert comparison.differences == []
      assert comparison.shadow == UsageV2.__projector_name__()
      assert comparison.live == Usage.__projector_name__()
      assert comparison.shadow_rows == 1
      assert comparison.live_rows == 1
    end

    test "promote swaps statuses, bumps the version, and serving/2 follows", %{
      practice_id: practice_id
    } do
      build_both!(practice_id)

      assert {:ok, _comparison} = Promotion.promote(UsageV2, Usage)

      v2 = Ash.get!(Registry, UsageV2.__projector_name__(), authorize?: false)
      v1 = Ash.get!(Registry, Usage.__projector_name__(), authorize?: false)
      assert v2.status == :active
      assert v2.version == 2
      assert v1.status == :retired
      assert v1.version == 1

      assert Promotion.serving("test_practice_usage", [Usage, UsageV2]) == UsageV2
      assert Promotion.serving("test_practice_usage", [Usage]) == nil
    end

    test "events after promote reach both tables, and rollback restores", %{
      practice_id: practice_id
    } do
      build_both!(practice_id)
      assert {:ok, _} = Promotion.promote(UsageV2, Usage)

      log_two_notes!(practice_id)
      :ok = Server.flush(Usage.__projector_name__())
      :ok = Server.flush(UsageV2.__projector_name__())

      # The retired projector keeps draining, so rollback is instant.
      assert practice_row!(PracticeUsageStats, practice_id).notes_count == 4
      assert practice_row!(PracticeUsageStatsV2, practice_id).notes_count == 4

      # Rollback restores the retired projector; promote and rollback are
      # symmetrical swaps of the same pair.
      :ok = Promotion.rollback(Usage, UsageV2)

      v2 = Ash.get!(Registry, UsageV2.__projector_name__(), authorize?: false)
      v1 = Ash.get!(Registry, Usage.__projector_name__(), authorize?: false)
      assert v1.status == :active
      assert v1.version == 2
      assert v2.status == :retired
      assert v2.version == 2

      assert Promotion.serving("test_practice_usage", [Usage, UsageV2]) == Usage

      # Calling rollback again undoes it.
      :ok = Promotion.rollback(UsageV2, Usage)
      assert Promotion.serving("test_practice_usage", [Usage, UsageV2]) == UsageV2
    end

    test "rebuild! of a :shadow projector leaves it :shadow" do
      :ok = Promotion.build_shadow!(UsageV2)
      :ok = Rebuilder.rebuild!(UsageV2)

      assert registry_status(UsageV2.__projector_name__()) == :shadow
    end

    test "rebuild! of a :retired projector leaves it :retired" do
      Registry.initialize!(UsageV2.__projector_name__())

      Registry.mark_retired!(Ash.get!(Registry, UsageV2.__projector_name__(), authorize?: false))

      :ok = Rebuilder.rebuild!(UsageV2)

      assert registry_status(UsageV2.__projector_name__()) == :retired
    end

    test "rebuild! of an :active projector still restores :active" do
      Registry.initialize!(UsageV2.__projector_name__())
      :ok = Rebuilder.rebuild!(UsageV2)

      assert registry_status(UsageV2.__projector_name__()) == :active
    end
  end

  describe "promote/3 refusals" do
    test ":shadow_behind when the shadow checkpoint lags the log", %{practice_id: practice_id} do
      events = log_two_notes!(practice_id)

      Registry.initialize!(Usage.__projector_name__())
      :ok = Promotion.build_shadow!(UsageV2)

      # The shadow's checkpoint stops at the first event; the log has two.
      {:ok, cp} = Checkpoint.initialize(UsageV2.__projector_name__())
      Checkpoint.advance(cp, List.first(events).id)

      assert {:error, {:shadow_behind, shadow_last, log_last}} =
               Promotion.promote(UsageV2, Usage)

      assert shadow_last == List.first(events).id
      assert log_last == List.last(events).id

      # Refusal leaves both statuses untouched.
      assert registry_status(UsageV2.__projector_name__()) == :shadow
      assert registry_status(Usage.__projector_name__()) == :active
    end

    test ":shadow_behind on an empty shadow with a non-empty log", %{practice_id: practice_id} do
      log_two_notes!(practice_id)
      Registry.initialize!(Usage.__projector_name__())
      :ok = Promotion.build_shadow!(UsageV2)

      assert {:error, {:shadow_behind, nil, log_last}} = Promotion.promote(UsageV2, Usage)
      assert is_integer(log_last)
    end

    test ":shadow_drift when the shadow row is corrupt", %{practice_id: practice_id} do
      build_both!(practice_id)

      row = practice_row!(PracticeUsageStatsV2, practice_id)

      Ash.update!(row, %{ops: [{:set, :notes_count, 99}]},
        action: :apply_projection_ops,
        authorize?: false
      )

      assert {:error, {:shadow_drift, drifts}} = Promotion.promote(UsageV2, Usage)
      assert [%{field: :notes_count, expected: 2, actual: 99}] = drifts
    end

    test ":differs_from_live without, and success with, accept_differences?", %{
      practice_id: practice_id
    } do
      build_both!(practice_id)

      # Corrupt the LIVE table: the shadow still verifies against the log,
      # but the two tables disagree.
      row = practice_row!(PracticeUsageStats, practice_id)

      Ash.update!(row, %{ops: [{:set, :notes_count, 99}]},
        action: :apply_projection_ops,
        authorize?: false
      )

      assert {:error, {:differs_from_live, differences}} = Promotion.promote(UsageV2, Usage)

      grain = %{practice_id: practice_id, billing_period_start: ~D[2026-09-01]}
      assert [%{grain: ^grain, field: :notes_count, shadow: 2, live: 99}] = differences

      assert {:ok, _} = Promotion.promote(UsageV2, Usage, accept_differences?: true)
      assert registry_status(UsageV2.__projector_name__()) == :active
    end

    test ":unexpected_status when the shadow is :active" do
      Registry.initialize!(Usage.__projector_name__())
      Registry.initialize!(UsageV2.__projector_name__())
      v2_name = UsageV2.__projector_name__()

      Registry.mark_active!(Ash.get!(Registry, UsageV2.__projector_name__(), authorize?: false))

      assert {:error, {:unexpected_status, ^v2_name, :active}} =
               Promotion.promote(UsageV2, Usage)
    end

    test ":unexpected_status when the live projector is :shadow" do
      Registry.initialize!(Usage.__projector_name__())
      :ok = Promotion.build_shadow!(UsageV2)
      v1_name = Usage.__projector_name__()

      Registry.mark_shadow!(Ash.get!(Registry, Usage.__projector_name__(), authorize?: false))

      assert {:error, {:unexpected_status, ^v1_name, :shadow}} =
               Promotion.promote(UsageV2, Usage)
    end

    test "different families raise" do
      assert_raise ArgumentError, ~r/share a family/, fn ->
        Promotion.promote(Usage, UserLifetime)
      end

      assert_raise ArgumentError, ~r/share a family/, fn ->
        Promotion.rollback(Usage, UserLifetime)
      end
    end

    test "the same projector twice raises" do
      assert_raise ArgumentError, ~r/two different projectors/, fn ->
        Promotion.promote(UsageV2, UsageV2)
      end

      assert_raise ArgumentError, ~r/two different projectors/, fn ->
        Promotion.rollback(Usage, Usage)
      end
    end

    test "a second promote loses and leaves statuses consistent", %{practice_id: practice_id} do
      build_both!(practice_id)

      assert {:ok, _} = Promotion.promote(UsageV2, Usage)

      v2_name = UsageV2.__projector_name__()

      assert {:error, {:unexpected_status, ^v2_name, :active}} =
               Promotion.promote(UsageV2, Usage)

      assert registry_status(UsageV2.__projector_name__()) == :active
      assert registry_status(Usage.__projector_name__()) == :retired
    end

    test "rollback with wrong statuses is refused" do
      :ok = Promotion.build_shadow!(UsageV2)
      v2_name = UsageV2.__projector_name__()

      assert {:error, {:unexpected_status, ^v2_name, :shadow}} =
               Promotion.rollback(UsageV2, Usage)
    end
  end

  # ExUnit's per-test supervisor keys children by id, so starting the Server
  # for two projector modules in one test needs distinct ids.
  defp start_server!(projector) do
    start_supervised!({Server, projector}, id: {Server, projector.__projector_name__()})
  end

  # Live v1 serving, shadow v2 marked and drained, both rows built.
  defp build_both!(practice_id) do
    start_server!(Usage)
    log_two_notes!(practice_id)
    :ok = Server.flush(Usage.__projector_name__())

    :ok = Promotion.build_shadow!(UsageV2)
    start_server!(UsageV2)
    :ok = Server.flush(UsageV2.__projector_name__())
  end

  defp log_two_notes!(practice_id) do
    for _ <- 1..2 do
      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => @period}
      )
    end
  end

  defp registry_status(name) do
    Ash.get!(Registry, name, authorize?: false).status
  end

  defp practice_row!(resource, practice_id) do
    Ash.read_one!(
      resource |> Ash.Query.filter(practice_id == ^practice_id),
      authorize?: false
    )
  end
end
