defmodule AshEvents.Projections.Events.RecordIdAdvisoryLockKeyGenerator do
  @moduledoc """
  Custom advisory lock key generator for AshEvents.

  AshEvents uses `pg_advisory_xact_lock` (transaction-level) to serialise
  concurrent writes to the same event stream. The default implementation keys
  the lock on `changeset.tenant` (practice_id for our tenanted resources), which
  means **every Note in the same practice shares one lock key**. That causes
  cross-test deadlocks in async test suites where multiple tests concurrently
  operate on Notes that belong to the same practice.

  Instead we key the lock on the **record's own primary key** (note.id /
  artifact.id). Each record gets a unique lock, so:

  - Different notes in the same practice don't block each other.
  - Nested actions on the *same* note within one transaction are safe because
    `pg_advisory_xact_lock` is re-entrant within the same transaction.
  - When neither a record id nor a tenant id is available we fall back to the
    default integer, which is safe for an audit-only (no-replay) event log.
  """

  use AshEvents.AdvisoryLockKeyGenerator

  def generate_key!(changeset, default_integer) do
    case Ash.Resource.Info.multitenancy_strategy(changeset.resource) do
      nil ->
        default_integer

      :context ->
        default_integer

      :attribute ->
        record_id = record_id_from_changeset(changeset)

        cond do
          valid_uuid?(record_id) -> uuid_to_int(record_id)
          valid_uuid?(changeset.tenant) -> uuid_to_int(changeset.tenant)
          is_integer(changeset.tenant) -> changeset.tenant
          true -> default_integer
        end
    end
  end

  # For update/destroy actions the record id lives in changeset.data.
  defp record_id_from_changeset(%{data: %{id: id}}) when is_binary(id), do: id
  # For create actions the id may already be set in changeset.attributes.
  defp record_id_from_changeset(%{attributes: %{id: id}}) when is_binary(id), do: id
  defp record_id_from_changeset(_), do: nil

  defp uuid_to_int(uuid) when is_binary(uuid) do
    <<hi::binary-size(8), lo::binary-size(8)>> =
      uuid
      |> String.replace("-", "")
      |> Base.decode16!(case: :mixed)

    <<hi_int::signed-32, _rest::binary>> = hi
    <<lo_int::signed-32, _rest::binary>> = lo

    [hi_int, lo_int]
  end

  defp valid_uuid?(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false
end
