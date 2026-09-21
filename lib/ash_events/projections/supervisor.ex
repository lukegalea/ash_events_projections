# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Supervisor do
  @moduledoc """
  Starts one `AshEvents.Projections.LeaderMonitor` per configured projector,
  plus a `AshEvents.Projections.PubSubListener` to relay Phoenix.PubSub commit
  notifications to the appropriate `Server` processes.

  Each `LeaderMonitor` races to register and start its `Server` globally.
  Only one wins across the cluster; the others stand by and take over
  automatically if the leader node goes down.

  Add to your application's supervision tree:

      children = [
        AshEvents.Projections.Supervisor,
        ...
      ]

  Configure projectors in `config.exs`:

      config :ash_events_projections,
        projectors: [MyApp.Projections.NotesPerDayProjector],
        start_projectors?: true,
        start_probe?: true

  ## Options

  `start_link/1` accepts a keyword list that overrides specific
  `AshEvents.Projections.Config` keys without touching application env:

    * `:projectors` — list of projector modules to boot
    * `:start_projectors?` — `false` disables leader monitors entirely
    * `:start_probe?` — `false` disables the lag probe
    * `:name` — registered name for the supervisor process

  Anything else is read from application env.
  """

  use Supervisor

  alias AshEvents.Projections.Config

  def start_link(opts \\ []) do
    projectors =
      if Config.start_projectors?(opts) do
        Config.projectors(opts)
      else
        []
      end

    start_probe? = Config.start_probe?(opts)
    name = Keyword.get(opts, :name, __MODULE__)

    Supervisor.start_link(
      __MODULE__,
      {projectors, start_probe?},
      name: name
    )
  end

  @impl true
  def init({projectors, start_probe?}) do
    monitor_children =
      Enum.map(projectors, fn projector ->
        Supervisor.child_spec(
          {AshEvents.Projections.LeaderMonitor, projector},
          id: {AshEvents.Projections.LeaderMonitor, projector}
        )
      end)

    listener_children =
      if projectors != [] do
        [AshEvents.Projections.PubSubListener]
      else
        []
      end

    probe_children =
      if projectors != [] and start_probe? do
        [AshEvents.Projections.Probe]
      else
        []
      end

    Supervisor.init(
      listener_children ++ monitor_children ++ probe_children,
      strategy: :one_for_one
    )
  end
end
