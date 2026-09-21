# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Config do
  @moduledoc """
  Runtime configuration adapter for `ash_events_projections`.

  All host-application coupling — the Ecto repo, Phoenix.PubSub server, event
  log resource, table names, projector list, telemetry prefix — is read from
  `Application.get_env(:ash_events_projections, ...)`.

  Define these in `config/config.exs` (or per environment):

      config :ash_events_projections,
        repo: MyApp.Repo,
        pubsub: MyApp.PubSub,
        pubsub_topic: "ash_events_projections:new_event",
        event_log: MyApp.Events.Event,
        event_table: "ash_events",
        table_prefix: "ash_projection_",
        projectors: [MyApp.Projections.NotesPerDayProjector],
        start_projectors?: true,
        start_probe?: true,
        telemetry_prefix: [:ash_events_projections]

  Most accessors take an optional `opts` keyword list so callers may pass an
  explicit override (used by the supervisor `start_link/1` opts path) without
  going through application env.
  """

  @default_pubsub_topic "ash_events_projections:new_event"
  @default_event_table "ash_events"
  @default_table_prefix "ash_projection_"
  @default_telemetry_prefix [:ash_events_projections]

  @typedoc "Keyword list of config overrides; missing keys fall back to application env."
  @type opts :: keyword()

  @doc """
  The Ecto repo used for raw queries (event log scans, advisory locks, count
  shortcuts) and as the `repo` for the internal Checkpoint, DeadLetter and
  Registry resources.

  This is a hard requirement; raises if not configured and no override is given.
  """
  @spec repo(opts) :: module()
  def repo(opts \\ []) do
    fetch!(opts, :repo)
  end

  @doc """
  The Phoenix.PubSub server name. Required for cluster-wide projector wake-ups.
  """
  @spec pubsub(opts) :: module()
  def pubsub(opts \\ []) do
    fetch!(opts, :pubsub)
  end

  @doc """
  The PubSub topic events are broadcast on after they are committed.
  Defaults to `"#{@default_pubsub_topic}"`.
  """
  @spec pubsub_topic(opts) :: String.t()
  def pubsub_topic(opts \\ []) do
    get(opts, :pubsub_topic, @default_pubsub_topic)
  end

  @doc """
  The host application's AshEvents event log resource. Used by projectors as the
  default `event_log:` when not overridden in their `use` opts.
  """
  @spec event_log(opts) :: module() | nil
  def event_log(opts \\ []) do
    get(opts, :event_log, nil)
  end

  @doc """
  The physical Postgres table the event log is stored in. Server.drain and
  several operations issue schemaless `from(e in AshEvents.Projections.Config.event_table(), ...)` queries
  against this name. Defaults to `"#{@default_event_table}"`.
  """
  @spec event_table(opts) :: String.t()
  def event_table(opts \\ []) do
    get(opts, :event_table, @default_event_table)
  end

  @doc """
  Prefix applied to internal projection-engine table names. Used by the
  Checkpoint, DeadLetter, and Registry resources to derive table names like
  `<prefix>checkpoints`. Defaults to `"#{@default_table_prefix}"`.
  """
  @spec table_prefix(opts) :: String.t()
  def table_prefix(opts \\ []) do
    get(opts, :table_prefix, @default_table_prefix)
  end

  @doc "List of projector modules to start under the supervisor."
  @spec projectors(opts) :: [module()]
  def projectors(opts \\ []) do
    get(opts, :projectors, [])
  end

  @doc "Whether the supervisor should boot leader monitors. Defaults to `true`."
  @spec start_projectors?(opts) :: boolean()
  def start_projectors?(opts \\ []) do
    get(opts, :start_projectors?, true)
  end

  @doc "Whether the lag probe should run alongside the supervisor. Defaults to `true`."
  @spec start_probe?(opts) :: boolean()
  def start_probe?(opts \\ []) do
    get(opts, :start_probe?, true)
  end

  @doc """
  Telemetry event prefix. The probe emits `prefix ++ [:lag]`; ops modules may
  emit other suffixes. Defaults to `[:ash_events_projections]`.
  """
  @spec telemetry_prefix(opts) :: [atom()]
  def telemetry_prefix(opts \\ []) do
    get(opts, :telemetry_prefix, @default_telemetry_prefix)
  end

  # --- internals ---------------------------------------------------------

  defp get(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> Application.get_env(:ash_events_projections, key, default)
    end
  end

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case Application.fetch_env(:ash_events_projections, key) do
          {:ok, val} ->
            val

          :error ->
            raise """
            ash_events_projections requires `#{inspect(key)}` to be configured.

            Add this to your config:

                config :ash_events_projections,
                  #{key}: <value>

            See `AshEvents.Projections.Config` for the full list of keys.
            """
        end
    end
  end
end
