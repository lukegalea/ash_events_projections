# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.LeaderMonitorTest do
  use AshEvents.Projections.ProjectionCase, async: false

  alias AshEvents.Projections.LeaderMonitor
  alias AshEvents.Projections.Registry
  alias AshEvents.Projections.Server
  alias AshEvents.Projections.TestApp.Projections.PracticeUsageStats

  import AshEvents.Projections.TestApp.EventFactory

  @name "test_practice_usage_v1"

  test "elects itself as leader and starts a globally registered server" do
    start_supervised!({LeaderMonitor, Usage})

    pid = LeaderMonitor.server_pid(Usage)
    assert is_pid(pid)
    assert pid == :global.whereis_name({Server, @name})

    # Server.init registers the projector in the persistent registry.
    assert Ash.get!(Registry, @name, authorize?: false).status == :active
  end

  test "a server booted by the monitor processes events end to end" do
    start_supervised!({LeaderMonitor, Usage})

    log_event!(
      action: :note_created,
      practice_id: Ecto.UUID.generate(),
      metadata: %{"billing_period_start" => "2026-09-01"}
    )

    :ok = Server.flush(@name)

    counts =
      PracticeUsageStats
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.notes_count)

    assert counts == [1]
  end

  test "adopts an already-running server instead of restarting it" do
    original = start_supervised!({Server, Usage})

    start_supervised!({LeaderMonitor, Usage})

    assert LeaderMonitor.server_pid(Usage) == original
    assert Process.alive?(original)
    assert :global.whereis_name({Server, @name}) == original
  end

  test "server_pid/1 returns nil when no monitor is running" do
    assert LeaderMonitor.server_pid(Usage) == nil
  end
end
