# AshEvents.Projections

[![Hex.pm](https://img.shields.io/hexpm/v/ash_events_projections.svg)](https://hex.pm/packages/ash_events_projections)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ash_events_projections)
[![CI](https://github.com/lukegalea/ash_events_projections/actions/workflows/elixir.yml/badge.svg)](https://github.com/lukegalea/ash_events_projections/actions/workflows/elixir.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Event-driven projections for [AshEvents](https://hex.pm/packages/ash_events).

Define declarative projectors that asynchronously fold a centralized event log
into pre-aggregated stats tables, with checkpointing, dead-letter handling,
blue/green rebuilds, gap detection, and a full operations toolkit.

> Status: pre-1.0. The DSL surface may change between minor versions until
> 1.0 is cut.

---

## Why?

You have an event log (built with `AshEvents.EventLog`) that records every
domain event in your system. You want to answer "how many notes did this
practice complete this billing period?" in O(1) — not O(events).

AshEvents records what happened. `ash_events_projections` turns those events
into stats tables that update asynchronously, transactionally, and idempotently.
Each projector:

- declares which events it cares about and how to update its stats row,
- runs as a single global owner per node-cluster (`:global` registered),
- persists a checkpoint after every batch so crashes resume cleanly,
- isolates failed events in a per-projector dead-letter queue,
- can be rebuilt, replayed, time-traveled, and verified with built-in tools.

The same engine powers all four projectors in ScribbleVet's production setup
(practice usage, membership usage, user lifetime, member-daily) on top of a
shared `ash_events` log.

---

## Install

```elixir
# mix.exs
def deps do
  [
    {:ash_events, "~> 0.6"},
    {:ash_events_projections, "~> 0.1"}
  ]
end
```

Configure the adapter surface:

```elixir
# config/config.exs
config :ash_events_projections,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  event_log: MyApp.Events.Event,
  projectors: [MyApp.Projections.NotesPerDayProjector]
```

Add the supervisor to your application tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    AshEvents.Projections.Supervisor
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

In `config/test.exs`, disable the projectors and probe so they don't run during
the test suite (you can still call them explicitly):

```elixir
config :ash_events_projections,
  start_projectors?: false,
  start_probe?: false
```

Then run `mix ash_events_projections.install` for an Igniter-driven scaffold
that wires the rest.

---

## Define your first projection

A projection has two parts: a target resource that stores the stats, and a
projector that knows how to update it.

```elixir
defmodule MyApp.Projections.NotesPerDayStats do
  use Ash.Resource,
    domain: MyApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields [:user_id, :date]
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :date, :date, allow_nil?: false, public?: true
    attribute :notes_count, :integer, default: 0, allow_nil?: false, public?: true
    timestamps()
  end

  postgres do
    table "notes_per_day_stats"
    repo MyApp.Repo
  end
end

defmodule MyApp.Projections.NotesPerDayProjector do
  use AshEvents.Projections.Projector,
    name: "notes_per_day_v1",
    event_log: MyApp.Events.Event,
    projection_resource: MyApp.Projections.NotesPerDayStats

  grain fn event ->
    if event.user_id && event.action == :complete do
      %{user_id: event.user_id, date: DateTime.to_date(event.occurred_at)}
    end
  end

  project MyApp.Notes.Note, :complete, fn _event ->
    [{:increment, :notes_count, 1}]
  end
end
```

That's it. Generate migrations, run them, and the projector will drain new
`Note.complete` events into `notes_per_day_stats` rows asynchronously.

To read the stats from the user's row, attach the projection as a calculation:

```elixir
defmodule MyApp.Users.User do
  use Ash.Resource,
    extensions: [AshEvents.Projections.AttachProjection]

  attach_projection MyApp.Projections.NotesPerDayProjector do
    field :notes_today, :notes_count, default: 0
  end
end
```

`user.notes_today` is now a calculation that joins the projection on the
appropriate grain.

---

## Operations toolkit

```bash
mix ash_events_projections.lag           # one-line lag + DLQ snapshot
mix ash_events_projections.verify        # checks projectors are in sync
mix ash_events_projections.gaps          # detects event-id gaps in the log
mix ash_events_projections.rebuild --projection=notes_per_day_v1
mix ash_events_projections.bootstrap --projection=notes_per_day_v1
mix ash_events_projections.dlq inspect  --projection=notes_per_day_v1
mix ash_events_projections.dlq replay   --projection=notes_per_day_v1
mix ash_events_projections.event_growth
```

Mount `AshEvents.Projections.Lag.snapshot/0` behind any Phoenix controller for
a Kubernetes-style readiness gate:

```elixir
get "/health/projections", MyAppWeb.HealthController, :projections
```

See the [how-to guides](https://hexdocs.pm/ash_events_projections/how-to.html)
for the full runbook.

---

## Architecture

```
┌─────────────────┐   ┌───────────────┐   ┌──────────────┐
│ AshEvents log   │──▶│ NotifyProjectors│──▶│ PubsubListener│
│ (ash_events)    │   └───────────────┘   └──────┬───────┘
└─────────────────┘                              │
                                                 ▼
                                        ┌───────────────┐
                                        │   Server      │
                                        │ (per-projector)│
                                        └───────┬───────┘
                                                │
                       ┌────────────────────────┼──────────────────────┐
                       ▼                        ▼                      ▼
              ┌────────────────┐    ┌─────────────────┐    ┌──────────────────┐
              │ projection     │    │ Checkpoint      │    │ DeadLetter       │
              │ stats table    │    │                 │    │ (poison pills)   │
              └────────────────┘    └─────────────────┘    └──────────────────┘
```

See [Architecture](https://hexdocs.pm/ash_events_projections/architecture.html)
for the full picture, including `LeaderMonitor` (`:global` ownership across a
cluster), the `Registry` (rebuild safety), and the operations layer.

---

## License

MIT © 2026 Luke Galea and ash_events_projections contributors.
