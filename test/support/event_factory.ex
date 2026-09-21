# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.EventFactory do
  @moduledoc """
  Appends rows to the test event log through the event resource's real
  `:create` action so projection tests exercise the same shape of event the
  Server, Verify, and TimeTravel read back.
  """

  alias AshEvents.Projections.TestApp.Accounts.User
  alias AshEvents.Projections.TestApp.Events.Event

  @doc """
  Creates one event row. Options:

    * `:action` (required) — the action name (atom)
    * `:resource` — the source resource module (default: User)
    * `:action_type` — :create | :update | :destroy (default: :create)
    * `:occurred_at` — NaiveDateTime/DateTime (default: now)
    * `:practice_id` — practice uuid placed in metadata (and the row column)
    * `:user_id` — actor uuid (default: fresh uuid)
    * `:metadata` — extra metadata merged on top of the standard fields
    * `:data` — the event payload map
  """
  def log_event!(opts) do
    user_id = Keyword.get_lazy(opts, :user_id, &Ecto.UUID.generate/0)

    metadata =
      %{"user_id" => user_id}
      |> maybe_put("practice_id", opts[:practice_id])
      |> Map.merge(Enum.into(opts[:metadata] || %{}, %{}, fn {k, v} -> {to_string(k), v} end))

    Event
    |> Ash.Changeset.for_create(:create, %{
      record_id: Ecto.UUID.generate(),
      resource: Keyword.get(opts, :resource, User),
      action: Keyword.fetch!(opts, :action),
      action_type: Keyword.get(opts, :action_type, :create),
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
      metadata: metadata,
      data: Keyword.get(opts, :data, %{}),
      user_id: user_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
