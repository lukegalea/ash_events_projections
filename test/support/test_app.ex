defmodule AshEvents.Projections.TestApp do
  @moduledoc """
  Test-only application that hosts a minimal AshEvents wiring and the engine
  components required to exercise the extension.

  Started automatically by `mix.exs` when `MIX_ENV=test` so resources and
  ETS-backed state are available.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshEvents.Projections.TestRepo,
      {Phoenix.PubSub, name: AshEvents.Projections.TestPubSub}
    ]

    opts = [strategy: :one_for_one, name: AshEvents.Projections.TestApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
