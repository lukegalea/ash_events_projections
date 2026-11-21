<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This project is pre-1.0; minor versions may contain breaking DSL changes until
the API stabilizes.

## [Unreleased]

- Requires Elixir 1.20 or later.

### Added
- Initial extraction from a production host app into a standalone Ash extension.
- Shadow-then-promote rebuilds: `AshEvents.Projections.Promotion`
  (`build_shadow!/1`, `promote/3`, `rollback/2`, `serving/2`, `family/1`),
  `:shadow` and `:retired` registry statuses, `Verify.compare/3`, and the
  `mix ash_events_projections.{shadow,promote}` tasks.
- Configurable event-log partition column: `partition_column:` projector
  option (default `:practice_id`), with the shared
  `AshEvents.Projections.EventRow` reader.
- `AshEvents.Projections.Projector` DSL for defining event-driven projectors with
  stateless and stateful handlers.
- `AshEvents.Projections.ProjectionResource` Spark extension for declaring
  projection target resources with a `grain_fields` block.
- `AshEvents.Projections.AttachProjection` Spark extension for attaching
  projection-backed calculations to existing Ash resources.
- `AshEvents.Projections.Supervisor` and `Server` for asynchronous, checkpointed
  draining of an AshEvents event log into projection tables.
- `AshEvents.Projections.LeaderMonitor` for `:global`-based single-node
  ownership of each projector across a cluster.
- `AshEvents.Projections.NotifyProjectors` change for waking projectors after
  event commit via Phoenix.PubSub.
- `AshEvents.Projections.ExtractMetadataFields` change for backfilling
  configurable scalar fields from the AshEvents metadata map.
- `AshEvents.Projections.RecordIdAdvisoryLockKeyGenerator` strategy for
  consistent advisory-lock keys across event-log appends.
- `AshEvents.Projections.RequireOptIn` Spark verifier enforcing explicit action
  whitelists for event-emitting resources.
- Operations toolkit: `Bootstrap`, `Dlq`, `EventGrowth`, `Gaps`, `Reset`,
  `Verify`, `Rebuilder`, `Lag`, `TimeTravel`.
- Mix tasks: `ash_events_projections.{bootstrap,dlq,event_growth,gaps,lag,
  rebuild,reset,verify,install}`.
- HTTP-facing helper `AshEvents.Projections.Lag.snapshot/0` for readiness
  endpoints.
