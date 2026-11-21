<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Shadow-then-promote rebuilds

`AshEvents.Projections.Rebuilder.rebuild!/1` replays in place: the registry
flips to `:rebuilding`, the Server stops draining, the stats table is
truncated, and the log is replayed. That is the right tool when the replay is
short and reads can wait. When the replay is long — or the projection must
keep serving while you work — build a **shadow** copy instead and promote it
atomically:

  * A second projector module with a versioned name (`usage_v2`, same family
    as `usage_v1`) and its **own** projection resource and table.
  * It builds from event 0 while `usage_v1` keeps serving and draining.
  * `AshEvents.Projections.Promotion.promote/3` verifies the shadow against
    the log and against the live table, then swaps the two in one
    transaction. `rollback/2` swaps back.

Both projectors keep draining the whole time, so the swap moves only the
registry statuses — no catch-up burst afterwards.

## 1. Name the family

A projector name's family is the name without its trailing `_v<digits>`
suffix. `usage_v1` and `usage_v2` share the family `usage`; a name without
the suffix is its own family. Both sides of a promote/rollback must share a
family and have different names.

The new projector declares its own projection resource and table:

```elixir
defmodule MyApp.Projections.UsageStatsV2 do
  use Ash.Resource,
    domain: MyApp.Projections,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields [:practice_id, :billing_period_start]
  end

  # ... same attributes you want in v2 ...
end

defmodule MyApp.Projections.UsageProjectorV2 do
  use AshEvents.Projections.Projector,
    name: "usage_v2",
    event_log: MyApp.Events.Event,
    projection_resource: MyApp.Projections.UsageStatsV2

  # ... same grain and handlers as v1, or the new logic you are shipping ...
end
```

`grain_fields` must match the live resource or `Verify.compare/3` returns
`{:error, :grain_mismatch}`. Generate the migration for the new table with
`mix ash_postgres.generate_migrations`. Do not add the module to `projectors`
yet (see step 2).

## 2. Mark the shadow, then start it

Mark the projector `:shadow` **before** its Server starts, so the Server
never boots as a second serving projector. From a console on the deployed
code (the module is compiled but not yet in `projectors`):

```elixir
AshEvents.Projections.Promotion.build_shadow!(MyApp.Projections.UsageProjectorV2)
```

This marks the projector `:shadow` in the registry under the family advisory
lock and notifies the Server. Then add the module to `projectors` and
restart: the Server's registry upsert leaves the `:shadow` status alone, so
it boots into `:shadow` and builds from event 0. `:shadow` rows drain
normally; only `:rebuilding` short-circuits the Server.

When the module is already in `projectors` (for example a shadow rebuilt
after a handler fix), `mix ash_events_projections.shadow --projection=usage_v2`
does the same marking from the command line.

## 3. Wait for catch-up, then verify

```sh
mix ash_events_projections.lag
mix ash_events_projections.verify --projection=usage_v2
```

`Verify.run/2` replays the log in memory and diffs it against the shadow
table — the shadow must be right against the log on its own before it can
replace anything.

## 4. Compare with the live table

From a console:

```elixir
AshEvents.Projections.Operations.Verify.compare(MyApp.Projections.UsageProjectorV2, MyApp.Projections.UsageProjector)
```

The result reports row counts and a list of differences (`%{grain, field,
shadow, live}`); a grain present on one side only is one difference with
`field: :__row__`. If v2 intentionally computes different values, expect —
and review — differences here.

## 5. Promote

```sh
mix ash_events_projections.promote --projection=usage_v2 --live=usage_v1
```

`promote/3` stops at the first failed precondition and returns (prints) the
reason:

  * `{:unexpected_status, name, status}` — the registry is not in the
    `:shadow`/`:active` state promote expects (also returned when a
    concurrent promote wins the race).
  * `{:shadow_behind, shadow_last, log_last}` — the shadow's checkpoint has
    not reached the log's `max(id)`.
  * `{:shadow_drift, drifts}` — the shadow does not match the event log.
  * `{:differs_from_live, differences}` — the shadow differs from the live
    table. Pass `--accept-differences` (or `accept_differences?: true`) to
    promote anyway.

The swap is one transaction: family advisory lock, both registry rows
re-read and re-checked, promoted row set `:active` with its `version`
bumped, demoted row set `:retired`.

## 6. Read through `serving/2`

Application code should not hard-code which version is live:

```elixir
projector = AshEvents.Projections.Promotion.serving("usage")

stats_resource = projector.__projection_resource__()
```

`serving/2` returns the projector of the family whose registry status is
`:active` (or `:rebuilding`), or `nil`.

## 7. Roll back

```sh
mix ash_events_projections.promote --projection=usage_v1 --live=usage_v2 --rollback
```

`rollback/2` is the same swap in the other direction: the retired row goes
back to `:active` (version bumped) and the demoted one to `:retired`. The
old projector never stopped draining, so both tables are current and the
rollback is instant. Calling rollback again undoes it — promote and
rollback are symmetrical swaps of the same pair.

## 8. Retire the old table

Once you are confident the new version will stay, remove the old projector
module from `projectors` in config. Its registry row stays `:retired` and no
longer matters. Drop the old projection table in a later migration — do not
delete it in the same deploy that stops the projector.
