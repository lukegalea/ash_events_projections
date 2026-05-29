defmodule AshEvents.Projections.Probe do
  @moduledoc """
  Periodically samples `AshEvents.Projections.Lag.snapshot/0` and emits
  `[:ash_events_projections, :lag]` `:telemetry` events so AppSignal (and any
  other handler) can graph projector lag and dead-letter depth.

  Started by `AshEvents.Projections.Supervisor` whenever the configured
  projector list is non-empty. Each tick emits one event per projector with
  measurements `%{lag_events, lag_seconds, dlq_depth}` and metadata
  `%{name, status, leader_node}`.

  Disabled in tests via `config :ash_events_projections, :start_probe?, false`.
  """

  use GenServer
  require Logger

  alias AshEvents.Projections.Lag

  @default_interval :timer.seconds(30)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    emit_metrics()
    schedule(state.interval)
    {:noreply, state}
  end

  @doc false
  def emit_metrics do
    Enum.each(Lag.snapshot(), fn row ->
      :telemetry.execute(
        AshEvents.Projections.Config.telemetry_prefix() ++ [:lag],
        %{
          lag_events: row.lag_events,
          lag_seconds: row.lag_seconds,
          dlq_depth: row.dlq_depth
        },
        %{
          name: row.name,
          status: row.status,
          leader_node: row.leader_node
        }
      )
    end)
  rescue
    error ->
      Logger.warning("[Projections.Probe] emit_metrics failed: #{inspect(error)}")
      :ok
  end

  defp schedule(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
