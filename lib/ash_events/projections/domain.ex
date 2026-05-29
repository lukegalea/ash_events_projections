defmodule AshEvents.Projections.Domain do
  @moduledoc """
  Internal Ash domain that owns the engine's three persistence resources.

  Host applications do not need to register these in their own domains; the
  engine library hosts them. They are exposed via code-interface modules so
  callers do not need to know about the domain at all.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEvents.Projections.Checkpoint
    resource AshEvents.Projections.DeadLetter
    resource AshEvents.Projections.Registry
  end
end
