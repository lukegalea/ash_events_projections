# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.PartitionColumnTest do
  use AshEvents.Projections.ProjectionCase, async: false

  require Ash.Query

  alias AshEvents.Projections.EventRow
  alias AshEvents.Projections.Operations.Dlq
  alias AshEvents.Projections.Operations.Verify
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats
  alias AshEvents.Projections.TestApp.Projections.TenantUsageStats
  alias AshEvents.Projections.TestApp.Projectors.TenantUsage
  alias AshEvents.Projections.TestApp.Projectors.Usage
  alias AshEvents.Projections.TimeTravel

  # Exactly 16 bytes: if anything treated this text value as a raw uuid
  # binary, Ecto.UUID.load/1 would silently rewrite it as
  # "30313233-3435-3637-3839-616263646566".
  @tenant "0123456789abcdef"

  setup do
    TenantUsage.set_explode?(false)
    on_exit(fn -> TenantUsage.set_explode?(false) end)

    {:ok, practice_id: Ecto.UUID.generate()}
  end

  describe "default partition column" do
    test "the default projector still receives event.practice_id", %{practice_id: practice_id} do
      start_supervised!({Server, Usage})

      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"}
      )

      :ok = Server.flush(Usage.__projector_name__())

      row = practice_row!(practice_id)
      assert row.notes_count == 1
    end
  end

  describe "partition_column: :tenant_ref" do
    test "the projector receives event.tenant_ref and not event.practice_id", %{
      practice_id: practice_id
    } do
      start_supervised!({Server, TenantUsage})

      # A practice_id is also logged; if the engine keyed the partition value
      # under :practice_id, the tenant grain would be nil and no row would
      # exist at all.
      log_event!(action: :note_created, practice_id: practice_id, tenant_ref: @tenant)
      :ok = Server.flush(TenantUsage.__projector_name__())

      assert [%{tenant_ref: @tenant, notes_count: 1}] =
               Ash.read!(TenantUsageStats,
                 authorize?: false
               )
    end

    test "EventRow.normalize puts the partition under the configured key only" do
      row = %{
        id: 1,
        partition: @tenant,
        user_id: nil,
        occurred_at: nil,
        metadata: nil,
        data: nil,
        resource: "Elixir.AshEvents.Projections.TestApp.Accounts.User",
        action: "note_created",
        action_type: "create"
      }

      event = EventRow.normalize(row, :tenant_ref)

      assert event.tenant_ref == @tenant
      assert event.action == :note_created
      refute Map.has_key?(event, :practice_id)
    end

    test "Verify.run reports no drift for the tenant_ref projector" do
      start_supervised!({Server, TenantUsage})

      log_event!(action: :note_created, tenant_ref: @tenant)
      log_event!(action: :note_created, tenant_ref: "acme-corp")
      :ok = Server.flush(TenantUsage.__projector_name__())

      result = Verify.run(TenantUsage)

      assert result.projection_name == TenantUsage.__projector_name__()
      assert result.checked_rows == 2
      assert result.drifts == []
    end

    test "Dlq replay loads the event through the tenant_ref partition" do
      start_supervised!({Server, TenantUsage})
      TenantUsage.set_explode?(true)

      event = log_event!(action: :explode, tenant_ref: @tenant)
      :ok = Server.flush(TenantUsage.__projector_name__())

      assert [%{status: :failed, event_id: event_id}] = Dlq.list(TenantUsage.__projector_name__())
      assert event_id == event.id
      refute tenant_row!(@tenant)

      TenantUsage.set_explode?(false)
      assert %{replayed: 1, failed: 0, skipped: 0} = Dlq.replay(TenantUsage)

      assert tenant_row!(@tenant).notes_count == 1
    end

    test "TimeTravel replays through the tenant_ref partition" do
      log_event!(
        action: :note_created,
        tenant_ref: @tenant,
        occurred_at: ~N[2026-09-01 10:00:00]
      )

      log_event!(
        action: :note_created,
        tenant_ref: "acme-corp",
        occurred_at: ~N[2026-09-01 10:30:00]
      )

      state = TimeTravel.state_at(TenantUsage, @tenant, ~N[2026-09-01 11:00:00])
      assert state == %{notes_count: 1}
    end

    test "a text partition value of exactly 16 bytes round-trips unchanged", %{
      practice_id: practice_id
    } do
      start_supervised!({Server, TenantUsage})

      log_event!(action: :note_created, practice_id: practice_id, tenant_ref: @tenant)
      :ok = Server.flush(TenantUsage.__projector_name__())

      # byte_size(@tenant) == 16: a raw-uuid misread would rewrite the value.
      assert byte_size(@tenant) == 16
      assert tenant_row!(@tenant).tenant_ref == @tenant

      assert Verify.run(TenantUsage).drifts == []
    end
  end

  defp practice_row!(practice_id) do
    Ash.read_one!(
      PracticeUsageStats |> Ash.Query.filter(practice_id == ^practice_id),
      authorize?: false
    )
  end

  defp tenant_row!(tenant_ref) do
    Ash.read_one!(
      TenantUsageStats |> Ash.Query.filter(tenant_ref == ^tenant_ref),
      authorize?: false
    )
  end
end
