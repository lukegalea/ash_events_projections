<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Usage rules for ash_events_projections

Concise rules for AI-assisted coding inside an app that depends on
`ash_events_projections`. Pair these with the AshEvents rules.

## Configuration

The extension requires this app config block:

```elixir
config :ash_events_projections,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  event_log: MyApp.Events.Event,
  projectors: [list_of_projector_modules]
```

Optional keys, with their defaults (`AshEvents.Projections.Config`):
`pubsub_topic` (`"ash_events_projections:new_event"`), `event_table`
(`"ash_events"`), `table_prefix` (`"ash_projection_"`), `start_projectors?`
(`true`), `start_probe?` (`true`), `telemetry_prefix`
(`[:ash_events_projections]`). Set `start_projectors?: false` and
`start_probe?: false` in `config/test.exs` and drain with
`AshEvents.Projections.Server.flush/1`.

`repo` and `table_prefix` are also read with `Application.compile_env/3` by the
internal Checkpoint, DeadLetter and Registry resources, so they must be set in
compile-time config (`config/config.exs` or an env file), not only in
`config/runtime.exs`.

`AshEvents.Projections.Supervisor` must be added to the app's supervision tree,
after the repo and the PubSub server. `mix igniter.install ash_events_projections`
writes the config block and adds the supervisor.

## The event log

- Add `change AshEvents.Projections.Events.Changes.NotifyProjectors, on: [:create]`
  to the event log resource. Servers drain on boot, on that signal, and on
  `Server.flush/1`; there is no polling, so without it new events are not
  projected until the next restart or flush.
- The engine reads the event table with schemaless queries that select
  `id, practice_id, user_id, occurred_at, metadata, data, resource, action,
  action_type`. The table must have a `practice_id` column as well as the
  AshEvents columns; `AshEvents.Projections.Events.Changes.ExtractMetadataFields`
  can fill it from `metadata`.

## Defining a projection target

Use the `AshEvents.Projections.ProjectionResource` extension and declare the
grain fields:

```elixir
extensions: [AshEvents.Projections.ProjectionResource]

projection_resource do
  grain_fields [:user_id, :practice_id, :date]
end
```

The transformer auto-derives a `:by_grain` identity from the grain fields. Do
not declare it manually.

## Defining a projector

```elixir
use AshEvents.Projections.Projector,
  name: "<unique_versioned_name>",
  event_log: MyApp.Events.Event,
  projection_resource: MyApp.Projections.MyStats

grain fn event -> %{...} end

project MyApp.SomeResource, :some_action, fn event ->
  [{:increment, :some_count, 1}]
end
```

- The `name` must be unique and SHOULD be versioned (`_v1`, `_v2`) so a future
  rebuild can run side-by-side as a blue/green deploy.
- `event_log:` and `projection_resource:` are required `use` options; the
  `event_log` app config does not fill them in.
- `grain` takes a function (event → grain map, or a bare value for a
  single-field grain) or an atom (`grain :user_id` reads `event.user_id`,
  falling back to `event.data["user_id"]`). A grain of `nil` skips the event.
- Handlers can be arity-1 (stateless — most common) or arity-2 (stateful —
  load current row before deciding). Arity is detected at compile time.
- Return `nil`, `[]` or any other non-list from a handler to skip the event
  without changing state.
- Ops returned are a list of `{:increment, field, n}`, `{:decrement, field, n}`,
  `{:set, field, value}`, `{:max, field, value}`. There is no `:min` op.

## Attaching projections to existing resources

```elixir
extensions: [AshEvents.Projections.AttachProjection]

projections do
  attach_projection MyApp.Projections.MyStats, MyApp.Projections.MyProjector do
    field :name_in_parent, :name_in_stats, :integer, default: 0
  end
end
```

`attach_projection` takes the stats resource and the `via` projector.
`field` takes the calculation name, the stats column and the Ash type
(default `:integer`); `default` is returned when no stats row exists.

The `via` projector must define two functions by hand (the `Projector` macro
does not generate them): `current_grain_for_record/1`, which returns the grain
map for a source record (or `nil` to return the default), and
`preload_for_grain/0`, which returns the load list that record needs.

## Operations

Mix tasks:

- `mix ash_events_projections.lag` — one-shot lag + DLQ snapshot
- `mix ash_events_projections.verify [--projection=<name>]` — assertion-style sync check
- `mix ash_events_projections.gaps [--since-id=<n>]` — detect missing event ids
- `mix ash_events_projections.rebuild --projection=<name>` — truncate + replay
- `mix ash_events_projections.bootstrap --projection=<name>` — replay without truncate (rare)
- `mix ash_events_projections.dlq inspect|replay|purge --projection=<name>`
  (`replay` takes `--event-ids=1,2`; `purge` takes `--hard-delete`)
- `mix ash_events_projections.reset --projection=<name>` — clear checkpoint (dangerous)
- `mix ash_events_projections.event_growth [--days=<n>]` — event-log size per day

`AshEvents.Projections.TimeTravel.state_at(projector, grain_key, timestamp)`
replays one grain's events up to a timestamp. It costs O(events) and is for
debugging, not hot paths.

## Things to NEVER do

- Do not call `String.to_atom/1` on resource or action names read from the
  event log. The engine already maps these via `String.to_existing_atom/1`.
- Do not write to a projection's stats table outside the projector. The
  projector and its rebuilder are the only writers; the table is otherwise
  treated as read-only by app code.
- Do not skip `mix ash_events_projections.rebuild` and call `reset` instead —
  resetting without truncating causes increment-style ops to double-count.
- Do not embed business logic in the projection target resource. The projector
  is the rule. The resource is just the shape.

## Iron laws

Changes to this package are checked against the 26 Iron Laws (phxagents.dev/iron-laws;
background in `ash_enterprise/docs/research/phxagents-iron-laws-and-codicil.md`).
`ash_agent_tools` ships a deterministic judge for them — `mix ash_agent.laws` reports
violations only, tiered definite/likely/review — wherever that dev tool is installed
(it is part of the `ash_enterprise` program, not a dependency of this package).

- Judge a change before claiming it done: `git diff main | mix ash_agent.laws - --diff`,
  and read the hits' context before acting — the judge is grep-tier, not a parser.
- The Oban laws are this package's home ground: #07 (jobs are idempotent and run
  at-least-once — the projector's advisory locks and replay checks exist for this),
  #08 (Oban args come back string-keyed through JSON), #09 (store IDs, not structs,
  so a retry re-reads fresh state).
- The laws with teeth inside a library generally: #10 (never `String.to_atom` on
  names read from the event log — see "Things to NEVER do" above), #14 (the
  projector servers and leader monitor belong in the supervision tree, never bare
  `Task.start`), #22 (verify before claiming done — compile, test, credo, docs,
  then say so), #26 (comments carry durable facts; the narrative belongs to the
  commit).
- The LiveView-facing laws govern the host applications wiring projections into
  UIs, not this package.
