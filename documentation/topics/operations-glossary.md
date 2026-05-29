# Operations glossary

Reference for every mix task and runtime helper in the operations toolkit.

## Mix tasks

| Task | Purpose |
|------|---------|
| `mix ash_events_projections.lag` | Print a snapshot of projector lag, status, and DLQ depth. The `--watch` flag refreshes every 5s. |
| `mix ash_events_projections.bootstrap --projection=<name>` | One-shot replay from id 0 for a brand-new projector being deployed for the first time. Acquires the rebuild advisory lock; fails fast if a rebuild is in progress. |
| `mix ash_events_projections.rebuild --projection=<name>` | Truncate the stats table and replay the entire event log. Use after fixing a projector's logic. |
| `mix ash_events_projections.reset --projection=<name>` | Zero the projector's checkpoint without touching stats. Rarely needed — usually `rebuild` is what you want. |
| `mix ash_events_projections.verify [--projection=<name>]` | Audit projection rows against the event log by running the projector logic in dry-run mode. Reports drift. |
| `mix ash_events_projections.gaps [--since-id=<n>]` | Detect missing `id` values in the event log (deletes, replication lag, manual surgery). |
| `mix ash_events_projections.dlq inspect --projection=<name>` | List dead-letter events for a projector. |
| `mix ash_events_projections.dlq replay --projection=<name> [--event-ids=1,2,3]` | Replay specific (or all `:failed`/`:pending_replay`) DLQ events. |
| `mix ash_events_projections.dlq purge --projection=<name> [--hard-delete]` | Mark events `:purged` (or delete with `--hard-delete`). |
| `mix ash_events_projections.event_growth [--days=N]` | Report event log row count and total payload bytes over the last N days. |

## Runtime helpers

| Module | Purpose |
|--------|---------|
| `AshEvents.Projections.Server.flush/1` | Synchronously drain the named projector. Tests call this after creating events. |
| `AshEvents.Projections.Server.notify/1` | Non-blocking signal to the named projector that new events are available. Used internally by the PubSub listener. |
| `AshEvents.Projections.Lag.snapshot/0` | List of `%{name:, status:, lag_events:, lag_seconds:, dlq_depth:, leader_node:}` maps. Suitable for `GET /health/projections` and graphs. |
| `AshEvents.Projections.Rebuilder.rebuild!/1` | Programmatic rebuild — same code path as `mix ...rebuild`. |
| `AshEvents.Projections.TimeTravel.state_at/3` | Compute a projector's state for a given grain key at an arbitrary point in time by replaying the relevant event slice. Useful for forensic debugging. |

## Telemetry

The `Probe` emits `<telemetry_prefix> ++ [:lag]` per projector per tick.
Default prefix `[:ash_events_projections]`, configurable via
`config :ash_events_projections, :telemetry_prefix, [...]`.

Measurements: `%{lag_events:, lag_seconds:, dlq_depth:}`.

Metadata: `%{name:, status:, leader_node:}`.

Attach AppSignal/Datadog handlers in your app's telemetry supervisor.
