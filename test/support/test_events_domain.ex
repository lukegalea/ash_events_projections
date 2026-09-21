# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.TestApp.Events do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshEvents.Projections.TestApp.Events.Event
  end
end
