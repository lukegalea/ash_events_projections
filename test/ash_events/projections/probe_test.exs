# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ProbeTest do
  use AshEvents.Projections.DataCase, async: false

  alias AshEvents.Projections.Probe
  alias AshEvents.Projections.TestApp.Projectors.{Usage, UserLifetime}

  @lag_event [:ash_events_projections_test, :lag]
  @handler_id {ProbeTest, :lag_handler}

  setup do
    Application.put_env(:ash_events_projections, :projectors, [Usage, UserLifetime])

    parent = self()

    :ok =
      :telemetry.attach(
        @handler_id,
        @lag_event,
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(@handler_id)
      Application.delete_env(:ash_events_projections, :projectors)
    end)

    :ok
  end

  test "emit_metrics/0 emits one lag event per configured projector" do
    Probe.emit_metrics()

    assert_receive {:telemetry, @lag_event, measurements, metadata}
    assert Map.has_key?(measurements, :lag_events)
    assert Map.has_key?(measurements, :lag_seconds)
    assert Map.has_key?(measurements, :dlq_depth)
    assert metadata.name == Usage.__projector_name__()
    assert metadata.status == :active
    assert metadata.leader_node == nil

    assert_receive {:telemetry, @lag_event, _measurements, metadata}
    assert metadata.name == UserLifetime.__projector_name__()
  end

  test "emit_metrics/0 with no configured projectors emits nothing" do
    Application.put_env(:ash_events_projections, :projectors, [])

    Probe.emit_metrics()

    refute_receive {:telemetry, @lag_event, _measurements, _metadata}
  end
end
