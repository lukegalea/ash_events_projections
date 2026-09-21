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

`AshEvents.Projections.Supervisor` must be added to the app's supervision tree.

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
- Handlers can be arity-1 (stateless — most common) or arity-2 (stateful —
  load current row before deciding). Arity is detected at compile time.
- Return `nil` from a handler to skip the event without changing state.
- Ops returned are a list of `{:increment, field, n}`, `{:set, field, value}`,
  `{:max, field, value}`, `{:min, field, value}`.

## Attaching projections to existing resources

```elixir
extensions: [AshEvents.Projections.AttachProjection]

attach_projection MyApp.Projections.MyProjector do
  field :name_in_parent, :name_in_stats, default: 0
end
```

The parent resource must implement `current_grain_for_record/1` indirectly
through the projector — see the projector's `current_grain_for_record/1`
callback.

## Operations

Mix tasks:

- `mix ash_events_projections.lag` — one-shot lag + DLQ snapshot
- `mix ash_events_projections.verify` — assertion-style sync check
- `mix ash_events_projections.gaps` — detect missing event ids
- `mix ash_events_projections.rebuild --projection=<name>` — truncate + replay
- `mix ash_events_projections.bootstrap --projection=<name>` — replay without truncate (rare)
- `mix ash_events_projections.dlq inspect|replay|purge --projection=<name>`
- `mix ash_events_projections.reset --projection=<name>` — clear checkpoint (dangerous)
- `mix ash_events_projections.event_growth` — event-log size per day

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
