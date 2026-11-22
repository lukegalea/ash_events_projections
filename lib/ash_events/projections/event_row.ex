# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.EventRow do
  @moduledoc """
  Single source of truth for reading rows out of the schemaless event log.

  The Server drain, `Operations.Verify`, `Operations.Dlq` and `TimeTravel`
  all used to duplicate the same select and the same row normalization. This
  module owns both halves, parameterized by the projector's partition column
  (`AshEvents.Projections.Projector.__partition_column__/0`, `:practice_id`
  by default):

  - `query/2` selects the columns the engine needs and casts the partition
    value to text in SQL, so a text partition value whose bytes are exactly
    16 long is never mistaken for a raw uuid binary by the normalization
    below.
  - `normalize/2` turns a raw row into the event map that handlers and grain
    functions receive, with the partition value under the configured column
    key (`event.practice_id` by default, `event.tenant_ref` when the
    projector declares `partition_column: :tenant_ref` — no other key).

  Callers add their own `where`/`limit`/`order_by` on top of `query/2`.
  """

  import Ecto.Query

  @default_partition_column :practice_id

  @doc """
  The partition column of `projector`: its `__partition_column__/0`, or
  `:practice_id` for a module that does not define one (a projector built by
  a wrapper macro that predates the `partition_column:` option).
  """
  @spec partition_column(module()) :: atom()
  def partition_column(projector) do
    Code.ensure_loaded(projector)

    if function_exported?(projector, :__partition_column__, 0),
      do: projector.__partition_column__(),
      else: @default_partition_column
  end

  @doc """
  Returns the base event-log query: id, partition, user_id, occurred_at,
  metadata, data, resource, action, action_type — ordered by id asc.
  """
  @spec query(Ecto.Queryable.t(), atom()) :: Ecto.Query.t()
  def query(table, partition_column) do
    from(e in table,
      select: %{
        id: e.id,
        partition: fragment("?::text", field(e, ^partition_column)),
        user_id: e.user_id,
        occurred_at: e.occurred_at,
        metadata: e.metadata,
        data: e.data,
        resource: e.resource,
        action: e.action,
        action_type: e.action_type
      },
      order_by: [asc: e.id]
    )
  end

  @doc """
  Normalizes one raw row from `query/2` into the event map handed to
  handlers and grain functions.
  """
  @spec normalize(map(), atom()) :: map()
  def normalize(row, partition_column) do
    # Explicit => keys come before keyword-shorthand entries.
    %{
      partition_column => row.partition,
      id: row.id,
      user_id: uuid_to_string(row.user_id),
      occurred_at: row.occurred_at,
      metadata: row.metadata || %{},
      data: row.data || %{},
      resource: to_atom(row.resource),
      action: to_atom(row.action),
      action_type: to_atom(row.action_type)
    }
  end

  # The partition value needs no uuid-binary conversion: query/2 already
  # cast it to text in SQL, and a text value that happens to be 16 bytes
  # must survive untouched. `user_id` is selected raw, so it keeps the
  # existing conversion.
  defp uuid_to_string(nil), do: nil

  defp uuid_to_string(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    {:ok, s} = Ecto.UUID.load(uuid)
    s
  end

  defp uuid_to_string(uuid), do: uuid

  # Use to_existing_atom/1: every legitimate value here is a module or action
  # name that has already been loaded (resources are compiled at boot, actions
  # are atoms in the resource DSL). Raising on unknown strings keeps malformed
  # rows visible instead of silently growing the atom table.
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_atom(a) when is_atom(a), do: a
end
