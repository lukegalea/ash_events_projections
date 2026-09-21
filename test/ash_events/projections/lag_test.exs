# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.LagTest do
  use AshEvents.Projections.DataCase, async: false

  require Ash.Query

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.DeadLetter
  alias AshEvents.Projections.Lag
  alias AshEvents.Projections.Registry
  alias AshEvents.Projections.TestApp.Projectors.{Usage, UserLifetime}

  import AshEvents.Projections.TestApp.EventFactory

  @usage_name "test_practice_usage_v1"
  @lifetime_name "test_user_lifetime_v1"

  @t1 ~N[2026-09-01 10:00:00]
  @t2 ~N[2026-09-01 11:00:00]
  @t3 ~N[2026-09-01 12:00:00]

  setup do
    Application.put_env(:ash_events_projections, :projectors, [Usage, UserLifetime])
    on_exit(fn -> Application.delete_env(:ash_events_projections, :projectors) end)

    {:ok, practice_id: Ecto.UUID.generate()}
  end

  test "snapshot_for/1 returns nil for an unknown projector" do
    assert Lag.snapshot_for("no_such_projector") == nil
  end

  test "snapshot_for/1 describes a projector that has never drained", %{practice_id: practice_id} do
    log_event!(
      action: :note_created,
      practice_id: practice_id,
      metadata: %{"billing_period_start" => "2026-09-01"},
      occurred_at: @t1
    )

    log_event!(
      action: :note_created,
      practice_id: practice_id,
      metadata: %{"billing_period_start" => "2026-09-01"},
      occurred_at: @t2
    )

    snapshot = Lag.snapshot_for(@usage_name)

    assert snapshot.name == @usage_name
    assert snapshot.status == :active
    assert snapshot.leader_node == nil
    assert snapshot.last_seen_id == nil
    assert snapshot.head_id != nil
    assert snapshot.lag_events == 2
    assert snapshot.lag_seconds == 0.0
    assert snapshot.dlq_depth == 0
  end

  test "lag_events counts only unprocessed events once a checkpoint exists", %{
    practice_id: practice_id
  } do
    events =
      for t <- [@t1, @t2, @t3] do
        log_event!(
          action: :note_created,
          practice_id: practice_id,
          metadata: %{"billing_period_start" => "2026-09-01"},
          occurred_at: t
        )
      end

    first = Enum.at(events, 0)
    Checkpoint.initialize!(@usage_name)
    Checkpoint.advance!(Ash.get!(Checkpoint, @usage_name, authorize?: false), first.id)

    snapshot = Lag.snapshot_for(@usage_name)

    assert snapshot.last_seen_id == first.id
    assert snapshot.lag_events == 2

    expected_seconds = Float.round(NaiveDateTime.diff(@t3, @t1, :microsecond) / 1_000_000, 3)
    assert snapshot.lag_seconds == expected_seconds
  end

  test "dlq_depth counts failed and pending_replay rows", %{practice_id: practice_id} do
    event =
      log_event!(
        action: :note_created,
        practice_id: practice_id,
        metadata: %{"billing_period_start" => "2026-09-01"},
        occurred_at: @t1
      )

    dlq =
      DeadLetter.record_failure!(%{
        projection_name: @usage_name,
        event_id: event.id,
        error_class: "RuntimeError",
        error_message: "boom",
        failed_at: DateTime.utc_now()
      })

    assert Lag.snapshot_for(@usage_name).dlq_depth == 1

    DeadLetter.mark_pending_replay!(dlq)
    assert Lag.snapshot_for(@usage_name).dlq_depth == 1

    DeadLetter.mark_replayed!(dlq)
    assert Lag.snapshot_for(@usage_name).dlq_depth == 0
  end

  test "status reflects the registry's :rebuilding state" do
    Registry.initialize!(@usage_name)
    Registry.mark_rebuilding!(Ash.get!(Registry, @usage_name, authorize?: false))

    assert Lag.snapshot_for(@usage_name).status == :rebuilding
  end

  test "snapshot/0 returns one row per configured projector and max_lag_events/0 tops them" do
    assert names = Enum.map(Lag.snapshot(), & &1.name)
    assert names == [@usage_name, @lifetime_name]

    log_event!(action: :something_else, occurred_at: @t1)

    # Both projectors have no checkpoints, so both lag behind by 1 event.
    assert Lag.max_lag_events() == 1
  end

  test "snapshot_for/1 is nil-safe for projectors with an empty log" do
    assert Lag.snapshot_for(@lifetime_name).head_id == nil
    assert Lag.snapshot_for(@lifetime_name).lag_events == 0
    assert Lag.snapshot_for(@lifetime_name).lag_seconds == 0.0
  end
end
