# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.CheckpointRegistryTest do
  use AshEvents.Projections.DataCase, async: true

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.Registry

  @name "checkpoint_registry_test_v1"
  @registry_name "checkpoint_registry_test_registry_v1"

  describe "Checkpoint" do
    test "initialize/1 is idempotent" do
      Checkpoint.initialize!(@name)
      Checkpoint.initialize!(@name)

      assert [%Checkpoint{projection_name: @name}] =
               Checkpoint |> Ash.read!(authorize?: false)
    end

    test "advance/2 records the last seen event and counts processed events" do
      checkpoint = Checkpoint.initialize!(@name)

      Checkpoint.advance!(checkpoint, 41)
      Checkpoint.advance!(Ash.get!(Checkpoint, @name, authorize?: false), 42)

      checkpoint = Ash.get!(Checkpoint, @name, authorize?: false)
      assert checkpoint.last_seen_event_id == 42
      assert checkpoint.events_processed == 2
    end

    test "reset/1 clears progress" do
      checkpoint = Checkpoint.initialize!(@name)
      Checkpoint.advance!(checkpoint, 42)

      Ash.get!(Checkpoint, @name, authorize?: false)
      |> Checkpoint.reset!()

      checkpoint = Ash.get!(Checkpoint, @name, authorize?: false)
      assert checkpoint.last_seen_event_id == nil
      assert checkpoint.events_processed == 0
    end
  end

  describe "Registry" do
    test "initialize/1 is idempotent and defaults to :active / version 1" do
      Registry.initialize!(@registry_name)
      Registry.initialize!(@registry_name)

      assert [%Registry{status: :active, version: 1}] =
               Registry |> Ash.read!(authorize?: false)
    end

    test "mark_rebuilding/1 and mark_active/1 flip the status" do
      registry = Registry.initialize!(@registry_name)

      Registry.mark_rebuilding!(registry)
      assert Ash.get!(Registry, @registry_name, authorize?: false).status == :rebuilding

      Registry.mark_active!(Ash.get!(Registry, @registry_name, authorize?: false))
      assert Ash.get!(Registry, @registry_name, authorize?: false).status == :active
    end

    test "bump_version/1 increments atomically" do
      registry = Registry.initialize!(@registry_name)

      Registry.bump_version!(registry)
      Registry.bump_version!(Ash.get!(Registry, @registry_name, authorize?: false))

      assert Ash.get!(Registry, @registry_name, authorize?: false).version == 3
    end
  end
end
