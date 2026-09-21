# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ApplyOpsChange do
  @moduledoc """
  An `Ash.Resource.Change` that translates projection op tuples into atomic
  Ash changeset operations.

  Supported ops:
    {:increment, field, n}  — field = field + n
    {:decrement, field, n}  — field = field - n
    {:set, field, value}    — field = value
    {:max, field, value}    — field = GREATEST(field, value)
  """

  use Ash.Resource.Change
  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_argument(:ops)
    |> Enum.reduce(changeset, fn
      {:increment, field, n}, cs ->
        Ash.Changeset.atomic_update(cs, field, Ash.Expr.expr(^Ash.Expr.atomic_ref(field) + ^n))

      {:decrement, field, n}, cs ->
        Ash.Changeset.atomic_update(cs, field, Ash.Expr.expr(^Ash.Expr.atomic_ref(field) - ^n))

      {:set, field, value}, cs ->
        Ash.Changeset.force_change_attribute(cs, field, value)

      {:max, field, value}, cs ->
        Ash.Changeset.atomic_update(
          cs,
          field,
          Ash.Expr.expr(fragment("GREATEST(?, ?)", ^Ash.Expr.atomic_ref(field), ^value))
        )
    end)
  end
end
