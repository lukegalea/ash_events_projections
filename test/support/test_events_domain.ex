defmodule AshEvents.Projections.TestApp.Events do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshEvents.Projections.TestApp.Events.Event
  end
end
