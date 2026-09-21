# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.DlqTest do
  use AshEvents.Projections.ProjectionCase, async: false

  require Ash.Query

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.DeadLetter
  alias AshEvents.Projections.Operations.Dlq
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Projections.DlqStats

  @name "test_dlq_v1"

  setup do
    Failing.set_explode?(false)
    on_exit(fn -> Failing.set_explode?(false) end)

    {:ok, practice_id: Ecto.UUID.generate()}
  end

  describe "ingestion" do
    test "a raising handler lands the event in the DLQ with error details", %{
      practice_id: practice_id
    } do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      event = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      assert [dlq] = Dlq.list(@name)
      assert dlq.event_id == event.id
      assert dlq.status == :failed
      assert dlq.error_class == "RuntimeError"
      assert dlq.error_message == "simulated projector crash"
      assert is_binary(dlq.stacktrace)
      assert %DateTime{} = dlq.failed_at
    end

    test "the checkpoint advances past a failed event and the projector keeps flowing", %{
      practice_id: practice_id
    } do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      _poison = log_event!(action: :explode, practice_id: practice_id)
      healthy = log_event!(action: :pop, practice_id: practice_id)

      :ok = Server.flush(@name)

      checkpoint = Ash.get!(Checkpoint, @name, authorize?: false)
      assert checkpoint.last_seen_event_id == healthy.id
      assert checkpoint.events_processed == 2

      # The poison event crashed before writing, but the healthy :pop event
      # on the same grain was still projected.
      assert stats_row(practice_id).explosions_handled == 1
      assert [%{status: :failed}] = Dlq.list(@name)
    end
  end

  describe "replay" do
    test "replays a failed event after the handler is fixed", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      event = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)
      refute stats_row(practice_id)

      Failing.set_explode?(false)
      assert %{replayed: 1, failed: 0, skipped: 0} = Dlq.replay(Failing)

      assert stats_row(practice_id).explosions_handled == 1

      dlq = dlq_row!(event.id)
      assert dlq.status == :replayed
      assert %DateTime{} = dlq.replayed_at
    end

    test "keeps the row in :failed when the handler still raises", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      event = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      assert %{replayed: 0, failed: 1, skipped: 0} = Dlq.replay(Failing)

      dlq = dlq_row!(event.id)
      assert dlq.status == :failed
      refute stats_row(practice_id)
    end

    test "scopes replay with :event_ids", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      first = log_event!(action: :explode, practice_id: practice_id)
      _second = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      Failing.set_explode?(false)
      assert %{replayed: 1, failed: 0, skipped: 0} = Dlq.replay(Failing, event_ids: [first.id])

      statuses =
        DeadLetter
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.event_id, &1.status})

      assert Map.get(statuses, first.id) == :replayed
      assert :failed in Map.values(statuses)
    end

    test "skips and purges rows whose event row is gone", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})

      DeadLetter.record_failure!(%{
        projection_name: @name,
        event_id: 9_999_999_999,
        error_class: "RuntimeError",
        error_message: "orphaned",
        failed_at: DateTime.utc_now()
      })

      assert %{replayed: 0, failed: 0, skipped: 1} = Dlq.replay(Failing)

      assert [%{status: :purged, event_id: 9_999_999_999}] = Dlq.list(@name, statuses: [:purged])
      assert stats_row(practice_id) == nil
    end

    test "replaying a healthy projector with an empty DLQ is a no-op" do
      start_supervised!({Server, Failing})
      assert %{replayed: 0, failed: 0, skipped: 0} = Dlq.replay(Failing)
    end
  end

  describe "listing and purging" do
    test "list/2 filters by status", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      event = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      dlq = dlq_row!(event.id)
      DeadLetter.mark_pending_replay!(dlq)

      assert [%{status: :pending_replay}] = Dlq.list(@name)
      assert Dlq.list(@name, statuses: [:replayed]) == []
      assert Dlq.list(@name, statuses: [:purged]) == []
    end

    test "purge/2 soft-marks rows purged by default", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      event = log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      assert Dlq.purge(@name) == 1

      dlq = dlq_row!(event.id)
      assert dlq.status == :purged
      assert Dlq.list(@name) == []
    end

    test "purge/2 hard-deletes rows when asked", %{practice_id: practice_id} do
      start_supervised!({Server, Failing})
      Failing.set_explode?(true)

      log_event!(action: :explode, practice_id: practice_id)
      :ok = Server.flush(@name)

      assert Dlq.purge(@name, hard_delete?: true) == 1

      assert DeadLetter |> Ash.read!(authorize?: false) == []
    end
  end

  defp stats_row(practice_id) do
    Ash.read_one!(DlqStats |> Ash.Query.filter(practice_id == ^practice_id), authorize?: false)
  end

  defp dlq_row!(event_id) do
    DeadLetter
    |> Ash.Query.filter(projection_name == ^@name and event_id == ^event_id)
    |> Ash.read_one!(authorize?: false)
  end
end
