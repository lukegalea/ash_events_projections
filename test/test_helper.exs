# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(AshEvents.Projections.TestRepo, :manual)
