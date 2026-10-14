# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Retention do
  @moduledoc """
  Retention & GDPR for the raw layer (design §9 risk 5) — explicitly
  scoped to the raw payloads; ADR 0024's platform-wide erasure is NOT
  resolved here.

  ## The partition strategy

  The raw table is RANGE-partitioned by `fetched_at` (the observation
  instant — §1.3's period basis), monthly, hand-maintained (the house
  pattern: ash_postgres codegen does not model partitioning). A DEFAULT
  partition catches everything not yet sliced; `ensure_partition!/3`
  creates an explicit month (with the per-partition identity exclusion —
  the identity is enforced WITHIN a partition; cross-month overlaps are
  precluded operationally: periods are `[fetched_at, next observation)`
  and backdated landings are refused).

  ## Drop-partition purge — an explicit, audited operator action

  `purge_before/2` drops whole monthly partitions older than the
  threshold. It requires `confirmed: true` (and a region, for the
  tombstone), counts the rows first, drops, and records ONE ledger
  tombstone per partition — `:"retention.partition_purged"`, carrying
  STRUCTURAL facts only (partition name, row count) — never payloads.
  The DEFAULT partition is never dropped (mixed data; purge it by
  erasure or by manual operation, consciously).

  ## Erasure-as-event

  `erase_subject/4` records the tombstone FIRST —
  `:"retention.subject_erased"`, subject descriptor = the erased
  subject — then deletes the subject's raw rows through the table
  machinery. The ledger's canonical payloads stay: they are
  PII-minimal by design (BIZEV-5's mapping rules — structural facts
  only), and the tombstone is the ledger's native answer to GDPR.

  ## The honesty note (re-sync after erasure)

  Erasure is LOCAL retention, not source revision: the SOURCE still
  holds its data, and the next sync re-lands the subject's current
  state as NEW history (fresh periods, fresh cursor positions). The
  erased instants stay erased — a re-sync never resurrects purged
  history, it re-observes the present.
  """

  @partition_prefix_re ~r/^(.+)_(\d{4})_(\d{2})$/

  # ── the partition machinery ───────────────────────────────────────────

  @doc "The raw table's name for a SourceRecord resource."
  @spec table(module()) :: String.t()
  def table(source_record) do
    AshPostgres.DataLayer.Info.table(source_record)
  end

  @doc "The repo for a SourceRecord resource."
  @spec repo(module()) :: module()
  def repo(source_record) do
    AshPostgres.DataLayer.Info.repo(source_record)
  end

  @doc """
  Ensures an explicit monthly partition exists for `month`
  (`~D[2026-10-01]`, any day, or `"2026-10"`) and carries the identity
  exclusion. Idempotent. The DEFAULT partition already exists and needs
  no ensuring.
  """
  @spec ensure_partition!(module(), String.t() | Date.t()) :: :ok
  def ensure_partition!(source_record, month) do
    {name, from, to} = month_bounds(table(source_record), month)
    repo = repo(source_record)

    repo.query!(
      "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF #{table(source_record)} " <>
        "FOR VALUES FROM ('#{Date.to_iso8601(from)}') TO ('#{Date.to_iso8601(to)}')"
    )

    add_identity_exclusion(repo, name)
    :ok
  end

  # ── drop-partition purge (the audited operator action) ────────────────

  @doc """
  Drops whole monthly partitions whose period ends at or before
  `before`, recording one ledger tombstone per dropped partition.

  Options (all required unless noted):

    * `:before` — the retention threshold; partitions ending at/before
      it are dropped (a partition `[from, to)` is droppable when
      `to <= before`).
    * `:region` — the tombstone's region (retention is region-scoped, §6).
    * `:confirmed` — MUST be `true`: this is a destructive, explicit
      operator action; the default (nil) refuses.

  Returns `{:ok, %{dropped: [partition names], rows: total dropped,
  tombstones: n}}`. The DEFAULT partition is never dropped.
  """
  @spec purge_before(module(), module(), keyword()) ::
          {:ok, %{dropped: [String.t()], rows: non_neg_integer(), tombstones: non_neg_integer()}}
          | {:error, :unconfirmed | {:missing_option, atom()}}
  def purge_before(source_record, ledger, opts) do
    if is_list(opts) and Keyword.get(opts, :confirmed) == true do
      purge_before_confirmed(source_record, ledger, opts)
    else
      {:error, :unconfirmed}
    end
  end

  defp purge_before_confirmed(source_record, ledger, opts) do
    with {:ok, before} <- fetch_opt(opts, :before),
         {:ok, region} <- fetch_opt(opts, :region) do
      source_record
      |> droppable_partitions(before)
      |> Enum.reduce({:ok, %{dropped: [], rows: 0, tombstones: 0}}, fn partition, acc ->
        {:ok, %{dropped: dropped, rows: rows, tombstones: tombstones}} = acc
        count = partition_rows(source_record, partition)

        drop_partition(source_record, partition)

        record_tombstone(
          ledger,
          region,
          :"retention.partition_purged",
          partition_name(partition),
          %{
            "partition" => partition_name(partition),
            "rows" => count
          }
        )

        {:ok,
         %{
           dropped: dropped ++ [partition_name(partition)],
           rows: rows + count,
           tombstones: tombstones + 1
         }}
      end)
    end
  end

  @doc "The droppable monthly partitions: explicit (not DEFAULT) partitions ending at/before `before`."
  @spec droppable_partitions(module(), DateTime.t()) :: [String.t()]
  def droppable_partitions(source_record, before) do
    source_record
    |> partition_tables()
    |> Enum.filter(fn name ->
      case partition_month(name) do
        nil -> false
        month -> Date.compare(next_month(month), DateTime.to_date(before)) != :gt
      end
    end)
  end

  defp partition_tables(source_record) do
    repo = repo(source_record)
    table = table(source_record)

    %{rows: rows} =
      repo.query!(
        "SELECT c.relname FROM pg_class c " <>
          "JOIN pg_inherits i ON c.oid = i.inhrelid " <>
          "JOIN pg_class p ON p.oid = i.inhparent " <>
          "WHERE p.relname = $1",
        [table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp partition_rows(source_record, partition) do
    %{rows: [[count]]} = repo(source_record).query!("SELECT count(*) FROM #{partition}")
    count
  end

  defp drop_partition(source_record, partition) do
    repo(source_record).query!("DROP TABLE #{partition}")
    :ok
  end

  # ── erasure-as-event ──────────────────────────────────────────────────

  @doc """
  Erases ONE subject's raw rows in `region`: the tombstone
  (`:"retention.subject_erased"`, subject descriptor = the erased
  subject) is recorded FIRST, then the raw rows are deleted through the
  table machinery. Returns `{:ok, %{deleted: n}}`.

  The honesty note: this is LOCAL retention. The source still holds its
  data; the next sync re-lands the subject's current state as NEW
  history — it never resurrects the erased instants.
  """
  @spec erase_subject(module(), module(), atom(), String.t(), keyword()) ::
          {:ok, %{deleted: non_neg_integer()}}
  def erase_subject(source_record, ledger, region, subject_external_id, _opts \\ []) do
    record_tombstone(ledger, region, :"retention.subject_erased", subject_external_id, %{
      "subject" => subject_external_id,
      "region" => to_string(region)
    })

    %{num_rows: deleted} =
      repo(source_record).query!(
        "DELETE FROM #{table(source_record)} WHERE region = $1 AND external_id = $2",
        [to_string(region), subject_external_id]
      )

    {:ok, %{deleted: deleted}}
  end

  # ── tombstones ────────────────────────────────────────────────────────

  # The ledger's native answer to GDPR: a tombstone row records THAT a
  # purge/erasure happened, with structural facts only — partition
  # names, row counts, the subject descriptor — never payloads.
  defp record_tombstone(ledger, region, kind, subject_external_id, data) do
    ledger.record!(%{
      event_kind: kind,
      region: region,
      residency_tag: to_string(region),
      subject_type: "retention",
      subject_external_id: subject_external_id,
      occurred_at: DateTime.utc_now(),
      provenance: %{
        "mapping_name" => "retention",
        "mapping_version_hash" => "retention",
        "source_record_id" => nil
      },
      data: data
    })
  end

  # ── partition naming/bounds ───────────────────────────────────────────

  defp month_bounds(table, month) when is_binary(month) do
    [y, m] = String.split(month, "-") |> Enum.map(&String.to_integer/1)
    month_bounds(table, Date.new!(y, m, 1))
  end

  defp month_bounds(table, %Date{} = first) do
    suffix = "#{first.year}_#{String.pad_leading(Integer.to_string(first.month), 2, "0")}"
    {table <> "_" <> suffix, first, next_month(first)}
  end

  defp next_month(%Date{year: y, month: 12}), do: Date.new!(y + 1, 1, 1)
  defp next_month(%Date{year: y, month: m}), do: Date.new!(y, m + 1, 1)

  defp partition_month(name) do
    case Regex.run(@partition_prefix_re, name) do
      [_, _prefix, y, m] -> Date.new!(String.to_integer(y), String.to_integer(m), 1)
      _ -> nil
    end
  end

  defp partition_name(partition), do: partition

  defp add_identity_exclusion(repo, partition_name) do
    # The identity is per partition: same source/stream/external_id/region
    # cannot hold two overlapping periods WITHIN the month. (Cross-month
    # overlaps are precluded operationally — periods are sequential and
    # backdated landings are refused.)
    repo.query!(
      "ALTER TABLE #{partition_name} " <>
        "ADD CONSTRAINT #{partition_name}_identity_excl " <>
        "EXCLUDE USING gist (source WITH =, stream WITH =, external_id WITH =, region WITH =, valid_at WITH &&)"
    )

    :ok
  rescue
    # duplicate_object: the partition already carries it (idempotent re-ensure)
    _ -> :ok
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
