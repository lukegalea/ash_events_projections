defmodule AshEvents.Projections.LeaderMonitor do
  @moduledoc """
  Guarantees exactly one running `AshEvents.Projections.Server` per projector
  across the cluster, with automatic failover when the hosting node dies.

  One `LeaderMonitor` runs per projector per node (started by
  `AshEvents.Projections.Supervisor`).  On boot, every monitor races to start
  the `Server` under the `:global` registry.  Only one wins; the others become
  standby monitors that watch the live `Server` pid.

  ## Failover flow

  1. Monitor subscribes to node-change events via
     `:net_kernel.monitor_nodes(true, node_type: :visible)`.
  2. Monitor calls `try_take_leadership/1`:
     - `{:ok, pid}` — this node won the `:global` race; the Server is now
       running here.  We link to it so a crash restarts the LeaderMonitor and
       triggers re-election.
     - `{:error, {:already_started, pid}}` — another node is running the
       Server.  We `Process.monitor/1` the remote pid so we receive `{:DOWN,...}`
       when it exits (whether due to a clean exit or a dead node).
  3. On `{:nodedown, _, _}` or `{:DOWN, ...}`: call `try_take_leadership/1`
     again.  `:global` has already released the name on the dead node, so
     whichever standby monitor wins the concurrent start-link becomes the new
     leader.
  4. A periodic 1-minute retry covers split-brain reconnect edge cases where
     the `:nodedown` event is delivered after `:global` has already re-elected
     but this node missed the signal.

  ## Single-node behaviour

  On a single node the `LeaderMonitor` detects the Server crash via the
  `{:DOWN, ...}` message and immediately re-starts it without involving the
  Supervisor.  If the `LeaderMonitor` itself crashes, the Supervisor restarts
  it and it re-starts the Server from scratch.

  ## Test usage

  In tests, start the monitor with `start_supervised!/1` instead of letting
  `AshEvents.Projections.Supervisor` manage it (the supervisor is disabled in
  the test environment via `start_projectors?: false`).
  """

  use GenServer

  alias AshEvents.Projections.Server

  require Logger

  @retry_interval :timer.minutes(1)

  # -------------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------------

  def start_link(projector) do
    GenServer.start_link(__MODULE__, projector, name: monitor_name(projector))
  end

  @doc "Returns the pid of the Server this monitor is currently managing or watching, if any."
  def server_pid(projector) do
    case GenServer.call(monitor_name(projector), :server_pid) do
      {:ok, pid} -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -------------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init(projector) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    schedule_retry()
    state = %{projector: projector, server_pid: nil, monitor_ref: nil}
    {:ok, try_take_leadership(state)}
  end

  @impl true
  def handle_call(:server_pid, _from, state) do
    {:reply, {:ok, state.server_pid}, state}
  end

  # A standby monitor sees the live Server go down (remote or local exit).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    Logger.info(
      "[Projections.LeaderMonitor] #{state.projector.__projector_name__()} server went down " <>
        "(reason: #{inspect(reason)}), attempting to take leadership"
    )

    {:noreply, try_take_leadership(%{state | server_pid: nil, monitor_ref: nil})}
  end

  # Node topology changed — attempt to take leadership in case the hosting node went down.
  @impl true
  def handle_info({node_event, _node, _info}, state)
      when node_event in [:nodeup, :nodedown] do
    Logger.debug("[Projections.LeaderMonitor] #{node_event} received, retrying leadership claim")
    {:noreply, try_take_leadership(state)}
  end

  # Periodic safety net in case a DOWN or nodedown was missed.
  @impl true
  def handle_info(:retry_leadership, state) do
    schedule_retry()
    {:noreply, try_take_leadership(state)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------------

  defp try_take_leadership(state) do
    projector = state.projector

    case Server.start_link(projector) do
      {:ok, pid} ->
        Logger.info(
          "[Projections.LeaderMonitor] #{projector.__projector_name__()} leader elected on #{node()}"
        )

        # Monitor (not link) so the LeaderMonitor stays alive to handle
        # {:DOWN, ...} and immediately re-elect without waiting for a Supervisor
        # restart cycle.  The Supervisor still restarts the LeaderMonitor if it
        # itself crashes for any other reason.
        demonitor(state.monitor_ref)
        ref = Process.monitor(pid)
        %{state | server_pid: pid, monitor_ref: ref}

      {:error, {:already_started, pid}} ->
        Logger.debug(
          "[Projections.LeaderMonitor] #{projector.__projector_name__()} already running on " <>
            "another node — standing by"
        )

        demonitor(state.monitor_ref)
        ref = Process.monitor(pid)
        %{state | server_pid: pid, monitor_ref: ref}

      {:error, reason} ->
        Logger.warning(
          "[Projections.LeaderMonitor] #{projector.__projector_name__()} start failed: " <>
            inspect(reason)
        )

        state
    end
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp monitor_name(projector),
    do: {:via, :global, {__MODULE__, projector.__projector_name__()}}

  defp schedule_retry, do: Process.send_after(self(), :retry_leadership, @retry_interval)
end
