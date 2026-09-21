# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.Projectors.Usage do
  @moduledoc """
  Stateless (arity-1) projector over the composite practice/period grain.

  Also implements the `AshEvents.Projections.AttachProjection` callbacks so it
  can serve as the `via:` projector for the Member resource's attached stats.
  """

  use AshEvents.Projections.Projector,
    name: "test_practice_usage_v1",
    event_log: AshEvents.Projections.TestApp.Events.Event,
    projection_resource: AshEvents.Projections.TestApp.Projections.PracticeUsageStats

  alias AshEvents.Projections.TestApp.Accounts.Member

  grain(fn event ->
    with practice_id when not is_nil(practice_id) <- event.practice_id,
         period when not is_nil(period) <- event.metadata["billing_period_start"] do
      %{practice_id: practice_id, billing_period_start: Date.from_iso8601!(period)}
    end
  end)

  # Matches any resource — exercises the project/2 (action-only) clause.
  project(:note_created, fn _event ->
    [{:increment, :notes_count, 1}]
  end)

  project(AshEvents.Projections.TestApp.Accounts.User, :care_card_created, fn _event ->
    [{:increment, :care_cards_count, 1}]
  end)

  project(AshEvents.Projections.TestApp.Accounts.User, :note_deleted, fn _event ->
    [{:decrement, :notes_count, 1}]
  end)

  project(AshEvents.Projections.TestApp.Accounts.User, :session_closed, fn event ->
    [{:set, :last_activity_at, event.occurred_at}]
  end)

  project(AshEvents.Projections.TestApp.Accounts.User, :peak_reached, fn event ->
    [{:max, :peak_notes, event.data["count"] || 0}]
  end)

  # Returns nil — exercises the handler skip path (no ops, no row).
  project(AshEvents.Projections.TestApp.Accounts.User, :ignored_action, fn _event ->
    nil
  end)

  # --- AttachProjection callbacks ---

  def preload_for_grain, do: []

  def current_grain_for_record(%Member{} = member) do
    if member.practice_id && member.billing_period_start do
      %{practice_id: member.practice_id, billing_period_start: member.billing_period_start}
    end
  end
end

defmodule AshEvents.Projections.TestApp.Projectors.UserLifetime do
  @moduledoc """
  Stateful (arity-2) projector: derives a running average from the current
  projection row, which is loaded before the handler runs.
  """

  use AshEvents.Projections.Projector,
    name: "test_user_lifetime_v1",
    event_log: AshEvents.Projections.TestApp.Events.Event,
    projection_resource: AshEvents.Projections.TestApp.Projections.UserLifetimeStats

  grain(fn event -> event.user_id end)

  project(:score_recorded, fn event, current ->
    score = event.data["score"] || 0
    count = Map.get(current, :scores_count, 0) + 1
    total = Map.get(current, :score_total, 0) + score

    [
      {:increment, :scores_count, 1},
      {:increment, :score_total, score},
      {:set, :avg_score, div(total, count)},
      {:max, :top_score, score}
    ]
  end)
end

defmodule AshEvents.Projections.TestApp.Projectors.Failing do
  @moduledoc """
  Projector whose handler raises whenever the `explode?` switch is flipped on
  via `:persistent_term`. Lets tests model the "handler bug" and "handler
  fixed" halves of the dead-letter lifecycle without recompiling.
  """

  use AshEvents.Projections.Projector,
    name: "test_dlq_v1",
    event_log: AshEvents.Projections.TestApp.Events.Event,
    projection_resource: AshEvents.Projections.TestApp.Projections.DlqStats

  @switch {:__MODULE__, :explode?}

  grain(fn event -> event.practice_id end)

  project(:explode, fn _event ->
    if :persistent_term.get(@switch, false), do: raise("simulated projector crash")

    [{:increment, :explosions_handled, 1}]
  end)

  # A healthy sibling action — processed normally even while the bug is on.
  project(:pop, fn _event ->
    [{:increment, :explosions_handled, 1}]
  end)

  @doc "Flip the simulated bug on/off (defaults to off)."
  def set_explode?(value), do: :persistent_term.put(@switch, value)
end
