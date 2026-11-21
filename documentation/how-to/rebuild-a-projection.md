<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Rebuild a projection

A rebuild replays the whole event log into a projection table. Pick the
variant by how long the replay takes and whether reads must keep working:

  * **In place** — `mix ash_events_projections.rebuild --projection=<name>`.
    Wraps `AshEvents.Projections.Rebuilder.rebuild!/1`: advisory lock,
    `:rebuilding` status (the Server stops draining), truncate, reset the
    checkpoint, restore the prior status, replay. Reads stall until the
    replay finishes. Right for short logs and staging environments. A
    rebuild restores whatever status the projector had — rebuilding a
    `:shadow` or `:retired` projector does not promote it.
  * **Side-by-side** — build a shadow projector and promote it, so the live
    table keeps serving throughout. See
    [Shadow-then-promote rebuilds](../tutorials/03-blue-green-deploys.md)
    and the `mix ash_events_projections.shadow` / `promote` tasks.
  * **Bootstrap** — `mix ash_events_projections.bootstrap --projection=<name>`
    replays without truncating, for purely additive fields that were `nil`
    (never double-counting `increment` fields; see the rules in
    `usage-rules.md`).

Do not call `reset` instead of rebuilding: replaying onto an untruncated
table double-counts increment-style ops.

## Choosing the partition column while you are at it

Each projector reads its own partition column from the event log
(`partition_column:` on `use AshEvents.Projections.Projector`, `practice_id`
by default). A versioned rebuild is the natural moment to change it — the
`_v2` projector can declare `partition_column: :tenant_ref` as long as the
event log has that column. Handlers and grain functions then receive
`event.tenant_ref` instead of `event.practice_id`.

## Watch the replay

`mix ash_events_projections.lag` shows each projector's lag in events and
seconds; `mix ash_events_projections.verify --projection=<name>` checks the
rebuilt table against the log when it finishes.
