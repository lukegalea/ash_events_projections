# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.InternalResource do
  @moduledoc """
  Helper macro used by the engine's three internal resources (`Checkpoint`,
  `DeadLetter`, `Registry`).

  Each internal resource needs to point at the host application's Ecto repo,
  and its physical Postgres table needs to inherit the configured
  `:table_prefix`. Both are resolved at the resource's compile time via
  `Application.compile_env/3`, which means changing host config triggers a
  rebuild of the dep — the normal Mix behavior.

  Usage:

      defmodule AshEvents.Projections.Checkpoint do
        use AshEvents.Projections.InternalResource, table: "checkpoints"

        # ... attributes/actions/identities ...
      end

  The macro emits the `use Ash.Resource` call and the `postgres do ... end`
  block with the configured `repo` and a table named
  `"\#{table_prefix}\#{table}"`.
  """

  @doc false
  defmacro __using__(opts) do
    table_suffix = Keyword.fetch!(opts, :table)
    domain = Keyword.get(opts, :domain, AshEvents.Projections.Domain)

    quote do
      @repo Application.compile_env(
              :ash_events_projections,
              :repo,
              AshEvents.Projections.TestRepo
            )

      @table_prefix Application.compile_env(
                      :ash_events_projections,
                      :table_prefix,
                      "ash_projection_"
                    )

      @ash_events_projections_table @table_prefix <> unquote(table_suffix)

      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer

      postgres do
        table(@ash_events_projections_table)
        repo(@repo)
      end
    end
  end
end
