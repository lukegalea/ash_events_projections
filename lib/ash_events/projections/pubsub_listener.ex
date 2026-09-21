defmodule AshEvents.Projections.PubSubListener do
  @moduledoc """
  Subscribes to the Phoenix PubSub projection topic on each node and forwards
  commit notifications to the appropriate `AshEvents.Projections.Server` processes.

  One instance runs per node (started by `AshEvents.Projections.Supervisor`).
  When an event row is committed, `AshEvents.Projections.Events.Changes.NotifyProjectors`
  broadcasts `{:event_committed, event_log_module}` on the
  the configured PubSub topic. Every node receives the
  broadcast; this process filters it to projectors that watch that event log
  and calls `Server.notify/1` for each, which wakes the global singleton Server
  wherever it is running in the cluster.
  """

  use GenServer

  alias AshEvents.Projections.{Config, Server}

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Config.pubsub(), Config.pubsub_topic())

    {:ok, %{}}
  end

  @impl true
  def handle_info({:event_committed, event_log_module}, state) do
    Config.projectors()
    |> Enum.filter(&(&1.__event_log__() == event_log_module))
    |> Enum.each(fn projector ->
      Server.notify(projector.__projector_name__())
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
