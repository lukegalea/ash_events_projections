# Getting started

This tutorial walks through wiring `ash_events_projections` into an Ash
application that already uses [`ash_events`](https://hexdocs.pm/ash_events).

By the end you will have:

  * The library installed and configured.
  * A `notes_per_day` projection resource backed by a real Postgres table.
  * A projector that folds `Note.create` events into daily counts.
  * The supervisor running, the projector reachable, and lag observable
    from a one-liner.

## 1. Add the dependency

```elixir
# mix.exs
def deps do
  [
    {:ash_events, "~> 0.6"},
    {:ash_events_projections, "~> 0.1"}
  ]
end
```

Run `mix deps.get`, then either:

  * `mix igniter.install ash_events_projections` (recommended — wires
    config + supervisor for you), or
  * Wire it manually (steps below).

## 2. Configure

```elixir
# config/config.exs
config :ash_events_projections,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  pubsub_topic: "myapp:projections:new_event",
  event_log: MyApp.Events.Event,
  event_table: "ash_events",
  table_prefix: "ash_projection_",
  projectors: [MyApp.Projections.NotesPerDayProjector],
  start_projectors?: true,
  start_probe?: true
```

In `config/test.exs` set `start_projectors?: false, start_probe?: false` so
tests can flush projections synchronously instead of racing the GenServer.

## 3. Add the supervisor

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    # ...
    AshEvents.Projections.Supervisor
  ]
  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

Start the supervisor **after** the repo and the PubSub server.

## 4. Define a projection target

```elixir
defmodule MyApp.Projections.NotesPerDayStats do
  use Ash.Resource,
    domain: MyApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields [:day]
  end

  attributes do
    attribute :day, :date, primary_key?: true, allow_nil?: false, public?: true
    attribute :count, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  postgres do
    table "notes_per_day_stats"
    repo MyApp.Repo
  end
end
```

The `ProjectionResource` extension automatically adds:

  * An `:apply_projection_ops` action that the engine uses to atomically
    apply `{:increment, :field, n}` / `{:set, :field, val}` / `{:max, :field, val}`
    operations.
  * An `:upsert_grain` action used to materialize a new grain row on demand.
  * A `truncate!/0` function the `Rebuilder` calls before replaying the log.

## 5. Define the projector

```elixir
defmodule MyApp.Projections.NotesPerDayProjector do
  use AshEvents.Projections.Projector,
    name: "notes_per_day_v1",
    event_log: MyApp.Events.Event,
    projection_resource: MyApp.Projections.NotesPerDayStats

  grain fn event ->
    case event.action_name do
      :create -> [day: DateTime.to_date(event.occurred_at)]
      _ -> nil
    end
  end

  project MyApp.Notes.Note, :create, fn _event ->
    [{:increment, :count, 1}]
  end
end
```

## 6. Verify

After running migrations and starting the supervisor:

```elixir
iex> MyApp.Notes.create!(%{body: "hello"})
iex> AshEvents.Projections.Server.flush("notes_per_day_v1")
iex> AshEvents.Projections.Lag.snapshot()
[
  %{name: "notes_per_day_v1", status: :active, lag_events: 0, lag_seconds: 0.0, ...}
]
```

`Lag.snapshot/0` is also what the `mix ash_events_projections.lag` task
prints and what the `Probe` emits as `:telemetry` events.

## Next steps

  * [Attaching projections to resources](02-attaching-projections.html)
  * [Blue/green projection deploys](03-blue-green-deploys.html)
  * [Inspect the DLQ](inspect-the-dlq.html)
