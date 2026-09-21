<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Architecture

`ash_events_projections` separates two concerns that traditional CRUD
applications conflate:

  * **The event log** (provided by [`ash_events`](https://hexdocs.pm/ash_events))
    is the system of record. Every business-meaningful change to a resource is
    appended as a row in the `ash_events` table by `AshEvents.EventLog`.
  * **Projections** are *materialized views* of that log — pre-aggregated
    rows that answer specific queries fast (e.g. "notes per practice per
    month") without re-scanning the log.

This library is the engine that asynchronously folds the log into projection
tables and gives operators the tools to inspect, rebuild, and verify them.

## Process topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Your application (one node)                       │
│                                                                         │
│   ┌────────────────────────┐   ┌────────────────────────────────────┐   │
│   │ AshEvents.EventLog     │   │ AshEvents.Projections.Supervisor   │   │
│   │  (append-only writes)  │   │   ├── LeaderMonitor(projector A) ──┼───► global Server A (one node only)
│   │                        │   │   ├── LeaderMonitor(projector B) ──┼───► global Server B (one node only)
│   │   AFTER COMMIT hook    │   │   ├── PubSubListener (per node)    │   │
│   │   broadcasts on        │   │   └── Probe (per node)             │   │
│   │   Phoenix.PubSub ──────┼──►│                                    │   │
│   └────────────────────────┘   └────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

A `LeaderMonitor` is started for every projector on every node. Each monitor
races to register a globally-named `Server` GenServer via Erlang's `:global`.
Only one wins per projector across the cluster; the others stand by and take
over automatically if the leader node disappears.

When an event commits, an `after_transaction` hook fires
`{:event_committed, event_log_module}` on the configured Phoenix.PubSub topic.
Every node's `PubSubListener` receives it, filters it down to the projectors
that watch that event log, and signals the matching `Server.notify/1`, which
asks the (cluster-wide-unique) Server to drain.

## Drain loop

Each `Server.drain/0` does roughly:

  1. Check the projector's `Registry.status` — if `:rebuilding`, return `:idle`
     immediately (a parallel rebuild owns the table).
  2. Read the projector's `Checkpoint.last_seen_event_id`.
  3. Stream the next batch of events with `id > last_seen_event_id`.
  4. For each event, in its own transaction:
       a. Call the projector's `apply_event/2`, which returns a list of
          *projection ops* (`{:increment, :field, n}`, `{:set, :field, val}`,
          `{:max, :field, val}`).
       b. Apply the ops atomically to the projection resource via
          `AshEvents.Projections.ApplyOpsChange`.
       c. Advance the checkpoint (`Checkpoint.advance(event_id)`) in the same
          transaction.

If the handler raises, the per-event transaction rolls back, a DLQ row is
inserted in a *fresh* transaction, the checkpoint advances past the offending
event, and the loop continues. Bad events never block the projector.

## Why two-table rebuilds work safely

To rebuild a projection, `Rebuilder.rebuild!/1` flips the projector's
`Registry.status` to `:rebuilding`, truncates the stats table, replays the
event log from id 0, and flips back to `:active`. The Server's drain loop
short-circuits to `:idle` while `:rebuilding` is set, so it cannot race the
rebuilder.

The rebuilder serialises on `pg_advisory_xact_lock(projector_name_hash)`
across the entire cluster — only one rebuild ever runs at a time per
projector.

## What's host-supplied

`ash_events_projections` deliberately owns none of:

  * The Ecto repo
  * The Phoenix.PubSub server
  * The event log resource
  * The list of projectors

All of those are read from `:ash_events_projections` application env via
`AshEvents.Projections.Config`. See the `AshEvents.Projections.Config`
moduledoc for the full list of keys.
