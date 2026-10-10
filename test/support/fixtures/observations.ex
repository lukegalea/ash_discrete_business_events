# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Observations do
  @moduledoc """
  Landing helpers shared by the SourceRecord tests: one builder for the
  design's running example (a Salesforce opportunity whose stage moves
  across the October 1 boundary), plus raw-history readers the contract
  assertions need (version counts and period bounds bypass the as-of
  collapse on purpose — the tests verify the history, not a view of it).
  """

  alias AshDiscreteBusinessEvents.Fixtures.SourceRecord

  @doc """
  A unique-per-call Salesforce-shaped opportunity id.

  Identity attributes must be globally unique across concurrent tests —
  two tests landing the same external id deadlock on the temporal
  upsert's row locks (the ash:testing deadlock rule; the exclusion
  constraint's tuple locks are physical, sandboxes notwithstanding).
  """
  def external_id do
    "0065f" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 13, "0")
  end

  @doc """
  The design's example observation: a Salesforce opportunity seen at
  `fetched_at`, overridable per test (keyword list or map). The external
  id is unique per call unless overridden.
  """
  def observation(overrides \\ []) do
    overrides = Map.new(overrides)

    base = %{
      source: :salesforce,
      stream: :opportunity,
      external_id: Map.get_lazy(overrides, :external_id, &external_id/0),
      region: :us,
      residency_tag: "us",
      raw_payload: %{
        "Id" => "0065f000003Xy7ZAAS",
        "StageName" => "Qualification",
        "SystemModstamp" => "2026-10-01T14:03:00.000+0000"
      },
      source_metadata: %{"adapter" => "bulk20"},
      cursor: %{"system_modstamp" => "2026-10-01T14:09:30.000+0000"},
      fetched_at: ~U[2026-10-01 14:09:41.000000Z]
    }

    Map.merge(base, overrides)
  end

  def land!(overrides \\ []) do
    SourceRecord.land!(observation(overrides))
  end

  @doc """
  Every version of an identity, oldest period first — read straight off
  the table (the as-of collapse would hide history from a plain read).
  Period bounds, payload, cursor and fetched_at are what the replay
  contract compares; `id` is shared by every version of a record.
  """
  def history(external_id, stream \\ :opportunity) do
    import Ecto.Query

    AshDiscreteBusinessEvents.Test.Repo.all(
      from(s in SourceRecord,
        where: s.external_id == ^external_id and s.stream == ^stream,
        order_by: [asc: fragment("lower(?)", s.valid_at)]
      )
    )
  end

  @doc """
  The replay-comparable projection of a version: period bounds, content,
  and the observation instant. Deliberately EXCLUDES `id` (stable across
  runs only by coincidence of generation) and `recorded_at` (the wall
  clock of when the version was written — its job is to differ on
  replay; the PERIODS must not).
  """
  def period_shape(version) do
    %{
      valid_at: %{lower: version.valid_at.lower, upper: version.valid_at.upper},
      source: version.source,
      stream: version.stream,
      external_id: version.external_id,
      region: version.region,
      residency_tag: version.residency_tag,
      raw_payload: version.raw_payload,
      cursor: version.cursor,
      fetched_at: version.fetched_at
    }
  end
end
