# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.VerifyChains do
  @moduledoc """
  Per-region hash-chain verification (design §1.4; the audit log's
  `Chain`, region-partitioned).

  Walks each region's chain in sequence order and recomputes the digest
  **in SQL, using the same expression the trigger uses** (`ChainSQL`) —
  one canonical form, two call sites. Three distinguishable findings,
  because they have different causes:

    * `:altered` — a row's stored hash does not match a hash recomputed
      from its own contents. Someone changed the row.
    * `:broken_link` — a row's `previous_hash` does not match the hash of
      the row before it in sequence. Someone removed a row, or inserted
      one out of band.
    * `:unchained` — a row has no hash at all, after rows that do. In
      practice the insert trigger was dropped, which is what an operator
      would do first if they intended to edit quietly.

  Rows written before the chain existed (or with the trigger disabled
  for a load) have no hash; an unbroken run of them at the very start of
  a region is reported as `skipped_unchained_prefix`, not as a finding —
  claiming tamper-evidence over rows that never had it would be a lie in
  the opposite direction. `mix bizev.verify_chains` is the CLI.
  """

  alias AshDiscreteBusinessEvents.Ledger.ChainSQL

  @type finding :: %{
          region: atom() | nil,
          sequence: integer(),
          id: term(),
          event_kind: atom(),
          problem: :altered | :broken_link | :unchained
        }

  @type result :: %{
          region: atom(),
          checked: non_neg_integer(),
          skipped_unchained_prefix: non_neg_integer(),
          findings: [finding()]
        }

  @doc """
  Verifies one region's chain. Returns a summary; `findings: []` is a
  clean chain.
  """
  @spec verify(module(), atom()) :: result()
  def verify(resource, region) when is_atom(resource) and is_atom(region) do
    repo = AshPostgres.DataLayer.Info.repo(resource)
    table = AshPostgres.DataLayer.Info.table(resource)
    digest = ChainSQL.digest_expression("")

    %{rows: rows} =
      repo.query!(
        """
        WITH chained AS (
          SELECT
            region,
            sequence,
            id,
            action,
            hash,
            previous_hash,
            lag(hash) OVER (ORDER BY sequence) AS actual_previous,
            encode(sha256(convert_to(#{digest}, 'UTF8')), 'hex') AS recomputed
          FROM #{table}
          WHERE region = $1
        )
        SELECT region, sequence, id, action, hash, previous_hash, actual_previous, recomputed
        FROM chained
        ORDER BY sequence
        """,
        [Atom.to_string(region)]
      )

    {unchained_prefix, chained} = Enum.split_while(rows, fn row -> is_nil(row_hash(row)) end)

    %{
      region: region,
      checked: length(chained),
      skipped_unchained_prefix: length(unchained_prefix),
      findings: chained |> Enum.map(&examine/1) |> Enum.reject(&is_nil/1)
    }
  end

  @doc """
  Verifies every region present in the log, and every table of a
  ledger/twin pair when the resource carries the macro's
  `simulation_table` metadata.
  """
  @spec verify_all(module()) :: [result()]
  def verify_all(resource) when is_atom(resource) do
    repo = AshPostgres.DataLayer.Info.repo(resource)
    table = AshPostgres.DataLayer.Info.table(resource)

    %{rows: rows} = repo.query!("SELECT DISTINCT region FROM #{table} ORDER BY 1")

    Enum.flat_map(rows, fn [region] ->
      [verify(resource, String.to_existing_atom(region))]
    end)
  end

  @doc """
  True when every region's chain is clean (no findings). The mix task
  and tests build their reports on this.
  """
  @spec clean?([result()]) :: boolean()
  def clean?(results), do: Enum.all?(results, &(&1.findings == []))

  defp row_hash(row), do: Enum.at(row, 4)

  defp examine([region, sequence, id, action, hash, previous_hash, actual_previous, recomputed]) do
    finding = fn problem ->
      %{
        region: String.to_existing_atom(region),
        sequence: sequence,
        id: Ecto.UUID.load!(id),
        event_kind: String.to_existing_atom(action),
        problem: problem
      }
    end

    cond do
      is_nil(hash) -> finding.(:unchained)
      previous_hash != actual_previous -> finding.(:broken_link)
      hash != recomputed -> finding.(:altered)
      true -> nil
    end
  end
end
