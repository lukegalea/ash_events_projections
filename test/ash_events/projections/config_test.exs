defmodule AshEvents.Projections.ConfigTest do
  use ExUnit.Case, async: false

  alias AshEvents.Projections.Config

  test "config keys read from application env with defaults" do
    assert Config.event_table() == "ash_events"
    assert Config.table_prefix() == "ash_projection_"
    assert Config.start_projectors?() == false
    assert Config.start_probe?() == false
    assert Config.pubsub_topic() == "ash_events_projections_test:new_event"
    assert Config.telemetry_prefix() == [:ash_events_projections_test]
    assert Config.repo() == AshEvents.Projections.TestRepo
    assert Config.pubsub() == AshEvents.Projections.TestPubSub
  end

  test "opts override application env" do
    assert Config.event_table(event_table: "other_events") == "other_events"
    assert Config.start_projectors?(start_projectors?: true) == true
    assert Config.projectors(projectors: [:a, :b]) == [:a, :b]
  end

  test "fetch! raises a helpful error when key is missing" do
    original = Application.get_env(:ash_events_projections, :repo)
    Application.delete_env(:ash_events_projections, :repo)

    try do
      assert_raise RuntimeError, ~r/requires `:repo`/, fn -> Config.repo() end
    after
      Application.put_env(:ash_events_projections, :repo, original)
    end
  end
end
