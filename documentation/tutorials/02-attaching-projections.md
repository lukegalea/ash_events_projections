<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Attaching projections to resources

> **Status:** scaffold.

Shows how to add the `AshEvents.Projections.AttachProjection` extension to a
domain resource so that columns of a projection's stats table appear on it as
calculations, looked up by the grain the `via` projector's
`current_grain_for_record/1` returns.
