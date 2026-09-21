# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.ProjectionCase do
  @moduledoc """
  Case template for tests that boot real `AshEvents.Projections.Server`
  processes.

  The sandbox runs in `{:shared, owner}` mode so the projector's GenServer —
  which drains on its own process — reads and writes the same sandboxed
  transaction as the test. Because shared mode cannot run concurrently,
  every test using this case must be `async: false`.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias AshEvents.Projections.TestApp.EventFactory
      alias AshEvents.Projections.TestApp.Projectors.{Failing, Usage, UserLifetime}
      alias AshEvents.Projections.TestRepo

      import AshEvents.Projections.ProjectionCase
      import AshEvents.Projections.TestApp.EventFactory
    end
  end

  setup _tags do
    owner = Sandbox.start_owner!(AshEvents.Projections.TestRepo, shared: false)
    Sandbox.mode(AshEvents.Projections.TestRepo, {:shared, owner})

    on_exit(fn ->
      Sandbox.mode(AshEvents.Projections.TestRepo, :manual)
      Sandbox.stop_owner(owner)
    end)

    :ok
  end
end
