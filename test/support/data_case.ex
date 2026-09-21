# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.DataCase do
  @moduledoc """
  Brings in Ecto sandbox and Ash test helpers for extension tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Query
      import AshEvents.Projections.DataCase

      alias AshEvents.Projections.TestRepo
    end
  end

  setup tags do
    pid =
      Sandbox.start_owner!(AshEvents.Projections.TestRepo,
        shared: not tags[:async]
      )

    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
