# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Operations.Gaps do
  @moduledoc """
  Detects gaps in `ash_events.id` — positions where the bigserial sequence
  skipped a value.

  PostgreSQL bigserial sequences advance on `nextval/0` regardless of whether
  the surrounding transaction commits, so a rolled-back insert leaves a hole.
  Most holes are benign rollbacks, but a sustained run of missing ids can
  also indicate:

    * Two concurrent transactions where the lower id committed AFTER the
      higher (the projection drain processes events strictly in id order, so
      a late-committing low id is permanently skipped — this is the well-known
      "auto-increment gap" risk).
    * Manual tampering or a bulk delete on `ash_events`.

  The detector returns a list of gap descriptors. Most workloads are happy
  with a periodic nightly run; the readiness probe does NOT incorporate gap
  detection because false positives from rolled-back inserts would be too
  noisy.

  See `backend/docs/runbooks/06-gap-detection.md`.
  """

  alias AshEvents.Projections.Config

  @type gap :: %{gap_start: integer(), gap_end: integer(), gap_size: integer()}

  @doc """
  Returns gaps between consecutive `ash_events.id` values, optionally
  bounded to ids `>= since_id`.
  """
  @spec detect(integer() | nil) :: [gap()]
  def detect(since_id \\ nil) do
    {sql, params} = build_query(since_id)

    Config.repo().query!(sql, params).rows
    |> Enum.map(fn [gap_start, gap_end, gap_size] ->
      %{gap_start: gap_start, gap_end: gap_end, gap_size: gap_size}
    end)
  end

  @doc """
  Total number of missing ids across all gaps. 0 means a contiguous sequence.
  """
  @spec missing_count(integer() | nil) :: non_neg_integer()
  def missing_count(since_id \\ nil) do
    detect(since_id)
    |> Enum.map(& &1.gap_size)
    |> Enum.sum()
  end

  defp build_query(nil) do
    {"""
     WITH numbered AS (
       SELECT id, LAG(id) OVER (ORDER BY id) AS prev_id FROM ash_events
     )
     SELECT prev_id + 1 AS gap_start,
            id - 1       AS gap_end,
            id - prev_id - 1 AS gap_size
     FROM numbered
     WHERE id - prev_id > 1
     ORDER BY gap_start
     """, []}
  end

  defp build_query(since_id) when is_integer(since_id) do
    {"""
     WITH numbered AS (
       SELECT id, LAG(id) OVER (ORDER BY id) AS prev_id
       FROM ash_events
       WHERE id >= $1
     )
     SELECT prev_id + 1 AS gap_start,
            id - 1       AS gap_end,
            id - prev_id - 1 AS gap_size
     FROM numbered
     WHERE id - prev_id > 1
     ORDER BY gap_start
     """, [since_id]}
  end
end
