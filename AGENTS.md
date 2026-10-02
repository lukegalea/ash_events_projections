<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_events_projections` (`AshEvents.Projections`), event-driven
projections for AshEvents.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- A projector folds the event log into a stats table asynchronously,
  transactionally, and idempotently.
- Each projector runs as a single global owner per cluster (`:global`
  registered).
- A checkpoint persists after every batch, so a crash resumes cleanly. A
  failed event goes to the dead-letter queue of its projector.
- The package is pre-1.0. The DSL surface can change between minor versions.
- Changes are judged against the 26 Iron Laws. Read "Iron laws" in
  `usage-rules.md`.

## Before you finish

CI runs `mix format --check-formatted`, `mix credo --strict`,
`mix test.create`, `mix test.migrate`, `mix test`, `mix docs`, and
`mix deps.audit`. Run them before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
