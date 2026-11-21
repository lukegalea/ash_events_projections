# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Promotion do
  @moduledoc """
  Shadow-then-promote lifecycle for projection rebuilds.

  Instead of truncating a live projection table and replaying in place
  (`AshEvents.Projections.Rebuilder.rebuild!/1`), a host can build a second
  projector with a versioned name (`usage_v2`) against its own projection
  table while the live one (`usage_v1`) keeps serving, compare the two, then
  swap them atomically — and roll back just as atomically.

  ## Lifecycle

  1. `build_shadow!/1` — run before (or after) deploying the new projector
     module. It marks the projector `:shadow` in the `Registry`; when the
     Server boots it drains from event 0 without serving reads. `Registry`
     rows are upserts, so `Server.init/1` never overwrites the `:shadow`
     status.
  2. The shadow drains the whole log; the live projector keeps serving and
     draining as before.
  3. `Verify.run/2` — once the shadow's lag is zero, check it against the
     event log on its own.
  4. `Verify.compare/3` — check the shadow against the live table.
  5. `promote/3` — refuses unless the shadow is caught up, self-verified and
     (unless `accept_differences?: true`) identical to live; then swaps the
     two in ONE transaction: the promoted row becomes `:active` with its
     `version` bumped, the demoted row becomes `:retired`.
  6. `rollback/2` — swaps back; calling it again undoes it again.
  7. Retire for real by leaving the old projector out of
     `Config.projectors()` once you are confident you will not roll back.

  `serving/2` is how reads resolve which projection resource to query:
  it returns the projector of a family whose registry status is `:active`
  (or `:rebuilding`), so application code never hard-codes `usage_v1`.

  A projector name's *family* is the name without its trailing `_v<digits>`
  suffix (`"usage_v2"` → `"usage"`); a name without the suffix is its own
  family. Both projectors in a promote/rollback must share a family and have
  different names.
  """

  alias AshEvents.Projections.{Checkpoint, Config, Rebuilder, Registry, Server}
  alias AshEvents.Projections.Operations.Verify

  import Ecto.Query, only: [from: 2]

  require Logger

  @type comparison :: Verify.comparison()

  @doc """
  Returns the family of a projector name or module: the name without a
  trailing `_v<digits>` suffix. A name without the suffix is its own family.

      Promotion.family("usage_v2")       # => "usage"
      Promotion.family("usage_v10")      # => "usage"
      Promotion.family("usage")          # => "usage"
  """
  @spec family(String.t() | module()) :: String.t()
  def family(name) when is_binary(name) do
    case Regex.run(~r/_v\d+$/, name) do
      nil ->
        name

      [suffix] ->
        binary_part(name, 0, byte_size(name) - byte_size(suffix))
    end
  end

  def family(module) when is_atom(module), do: family(module.__projector_name__())

  @doc """
  Marks `shadow_module` as `:shadow` so its Server builds from event 0 while
  the family's live projector keeps serving.

  Runs in one transaction under the family advisory lock, then notifies the
  Server. Needs no running Server: a host can call it before deploying the
  new projector module, and `Server.init/1`'s registry upsert leaves the
  existing `:shadow` status alone.

  Returns `:ok`; raises `ArgumentError` if the projector is already the
  family's serving projector.
  """
  @spec build_shadow!(module()) :: :ok
  def build_shadow!(shadow_module) do
    name = shadow_module.__projector_name__()
    fam = family(name)

    if serving?(name) do
      raise ArgumentError,
            "cannot build a shadow for #{name}: it is the family's serving projector"
    end

    Config.repo().transaction(fn ->
      Config.repo().query!("SELECT pg_advisory_xact_lock($1)", [Rebuilder.lock_key(fam)])

      {:ok, _} = Registry.initialize(name)
      registry = Ash.get!(Registry, name, authorize?: false)
      {:ok, _} = Registry.mark_shadow(registry)
      :ok
    end)
    |> unwrap_transaction!()

    Logger.info("[Projections.Promotion] #{name} marked :shadow; building from event 0")

    Server.notify(name)

    :ok
  end

  @doc """
  Promotes a shadow projector to serving, demoting the live one to `:retired`.

  Options:

    * `:accept_differences?` — when `true`, skips the requirement that the
      shadow be identical to the live table (it must still be caught up and
      self-verified against the event log).

  Steps, in order, stopping at the first failure:

    1. Both projectors must share a family (else `ArgumentError`) and have
       registry statuses `:shadow` and `:active` respectively.
    2. `Server.flush/1` on both, then the shadow's checkpoint must equal the
       event log's `max(id)` — an empty log counts as caught up.
    3. `Verify.run/2` on the shadow must find no drifts: the shadow is right
       against the event log.
    4. `Verify.compare/3` must find no differences with the live table.
    5. The swap commits in one transaction (see `swap/4`).

  Returns `{:ok, comparison}` on success, or `{:error, reason}` with:

    * `{:unexpected_status, name, status}` — registry statuses were not
      `:shadow`/`:active` (also raised when a concurrent promote wins).
    * `{:shadow_behind, shadow_last, log_last}` — the shadow's checkpoint is
      behind the event log.
    * `{:shadow_drift, drifts}` — the shadow does not match the event log.
    * `{:differs_from_live, differences}` — the shadow differs from the live
      table and `:accept_differences?` was not set.
  """
  @spec promote(module(), module(), keyword()) :: {:ok, comparison()} | {:error, term()}
  def promote(shadow_module, live_module, opts \\ []) do
    assert_swappable!(shadow_module, live_module)

    shadow_name = shadow_module.__projector_name__()
    live_name = live_module.__projector_name__()

    with :ok <- require_status(shadow_name, :shadow),
         :ok <- require_status(live_name, :active),
         :ok <- require_caught_up(shadow_name, live_name),
         :ok <- require_self_verified(shadow_module),
         compare_result when is_map(compare_result) <-
           run_compare(shadow_module, live_module, opts) do
      case swap(shadow_name, live_name, :shadow, :active) do
        :ok ->
          Logger.info("[Projections.Promotion] promoted #{shadow_name} over #{live_name}")

          {:ok, compare_result}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Rolls a promotion back: swaps the retired projector back to `:active` and
  the live one to `:retired`.

  Both projectors must share a family (else `ArgumentError`) and have
  registry statuses `:retired` and `:active` respectively. The swap is the
  same single transaction as `promote/3`, so calling `rollback/2` again
  undoes it — promote and rollback are symmetrical swaps of the same pair.
  """
  @spec rollback(module(), module()) :: :ok | {:error, term()}
  def rollback(retired_module, live_module) do
    assert_swappable!(retired_module, live_module)

    retired_name = retired_module.__projector_name__()
    live_name = live_module.__projector_name__()

    with :ok <- require_status(retired_name, :retired),
         :ok <- require_status(live_name, :active),
         :ok <- swap(retired_name, live_name, :retired, :active) do
      Logger.info("[Projections.Promotion] rolled back to #{retired_name}")
      :ok
    end
  end

  @doc """
  Returns the projector module of `family` whose registry status is `:active`
  or `:rebuilding`, or `nil` when the family has no serving projector. This
  is how a host resolves which projection resource to read.
  """
  @spec serving(String.t(), [module()]) :: module() | nil
  def serving(family, projectors \\ Config.projectors()) do
    projectors
    |> Enum.filter(&(family(&1) == family))
    |> Enum.find(fn module ->
      case Ash.get(Registry, module.__projector_name__(), authorize?: false) do
        {:ok, %{status: status}} -> status in [:active, :rebuilding]
        _ -> false
      end
    end)
  end

  # --- Checks ---

  defp serving?(name) do
    case Ash.get(Registry, name, authorize?: false) do
      {:ok, %{status: status}} -> status in [:active, :rebuilding]
      _ -> false
    end
  end

  defp assert_swappable!(a, b) do
    a_name = a.__projector_name__()
    b_name = b.__projector_name__()

    if a_name == b_name do
      raise ArgumentError,
            "promote/rollback needs two different projectors; got #{a_name} twice"
    end

    if family(a_name) != family(b_name) do
      raise ArgumentError,
            "projectors must share a family: #{a_name} (#{family(a_name)}) vs " <>
              "#{b_name} (#{family(b_name)})"
    end
  end

  defp require_status(name, expected) do
    case Ash.get(Registry, name, authorize?: false) do
      {:ok, %{status: ^expected}} ->
        :ok

      {:ok, %{status: other}} ->
        {:error, {:unexpected_status, name, other}}

      _ ->
        {:error, {:unexpected_status, name, nil}}
    end
  end

  defp require_caught_up(shadow_name, live_name) do
    Server.flush(shadow_name)
    Server.flush(live_name)

    shadow_last = checkpoint_last(shadow_name)
    log_last = log_max_id()

    if shadow_last == log_last do
      :ok
    else
      {:error, {:shadow_behind, shadow_last, log_last}}
    end
  end

  defp checkpoint_last(name) do
    case Ash.get(Checkpoint, name, authorize?: false) do
      {:ok, cp} -> cp && Map.get(cp, :last_seen_event_id)
      _ -> nil
    end
  end

  # Schemaless read of the event log's high-water mark.
  defp log_max_id do
    from(e in Config.event_table(), select: max(e.id))
    |> Config.repo().one()
  end

  defp require_self_verified(shadow_module) do
    result = Verify.run(shadow_module, flush: false)

    if result.drifts == [] do
      :ok
    else
      {:error, {:shadow_drift, result.drifts}}
    end
  end

  defp run_compare(shadow_module, live_module, opts) do
    case Verify.compare(shadow_module, live_module, flush: false) do
      {:error, :grain_mismatch} = error ->
        error

      comparison when is_map(comparison) ->
        if comparison.differences == [] or Keyword.get(opts, :accept_differences?, false) do
          comparison
        else
          {:error, {:differs_from_live, comparison.differences}}
        end
    end
  end

  # --- The atomic swap ---

  # One transaction: family advisory lock, re-read both registry rows and
  # re-check statuses (a concurrent promote/rollback must lose), then set
  # the promoted row :active with a version bump and the demoted row
  # :retired. The lock is keyed on the family so both directions of the
  # swap serialize.
  @doc false
  # Public only so tests can drive the in-lock status re-check directly.
  @spec swap(String.t(), String.t(), atom(), atom()) :: :ok | {:error, term()}
  def swap(promoted_name, demoted_name, expected_promoted, expected_demoted) do
    Config.repo().transaction(fn ->
      Config.repo().query!("SELECT pg_advisory_xact_lock($1)", [
        Rebuilder.lock_key(family(promoted_name))
      ])

      promoted = expect_status!(promoted_name, expected_promoted)
      demoted = expect_status!(demoted_name, expected_demoted)

      {:ok, _} = Registry.mark_active(promoted)
      {:ok, _} = Registry.bump_version(promoted)
      {:ok, _} = Registry.mark_retired(demoted)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Ecto returns {:ok, last_expression} on commit even when that expression
  # is an error tuple, so a losing swap rolls back explicitly with the error
  # payload instead of committing silently.
  defp expect_status!(name, expected) do
    case Ash.get(Registry, name, authorize?: false) do
      {:ok, %{status: ^expected} = row} ->
        row

      {:ok, %{status: other}} ->
        Config.repo().rollback({:unexpected_status, name, other})

      _ ->
        Config.repo().rollback({:unexpected_status, name, nil})
    end
  end

  defp unwrap_transaction!({:ok, :ok}), do: :ok
  defp unwrap_transaction!({:error, reason}), do: raise(reason)
end
