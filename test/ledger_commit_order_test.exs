# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LedgerCommitOrderTest do
  @moduledoc """
  The permanent measurement test (design §1.4, risk 2 — the audit log's
  lesson inherited verbatim): **within a region, sequence order is
  commit order**.

  The mechanics under test: the record path takes the per-region
  advisory xact lock BEFORE insert, in the same transaction, so a second
  writer for that region cannot be assigned its bigserial `sequence`
  until the first has committed. If the lock ever moves, loses xact
  scope, or stops being taken, consumers skip events *silently* — this
  test is what fires instead.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Ledger
  alias AshDiscreteBusinessEvents.Fixtures.LedgerEvents
  alias AshDiscreteBusinessEvents.Ledger.RegionLockKeyGenerator
  alias AshDiscreteBusinessEvents.Ledger.VerifyChains

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{subject: LedgerEvents.subject_external_id()}
  end

  test "a writer holding the region lock blocks the record path until it commits", %{
    subject: subject
  } do
    repo = AshDiscreteBusinessEvents.Test.Repo
    [k1, k2] = RegionLockKeyGenerator.key_for(:us)

    # Writer 1: takes the region lock the way the record path would, and
    # HOLDS the transaction open across a long stall.
    holder =
      Task.async(fn ->
        repo.transaction(fn ->
          repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [k1, k2])
          Process.sleep(400)

          LedgerEvents.record!(
            subject_external_id: subject,
            occurred_at: ~U[2026-10-01 14:03:00.000000Z]
          )
        end)
        |> then(fn {:ok, record} -> record end)
      end)

    # Writer 2: starts while writer 1 holds the lock, and must WAIT.
    waiter =
      Task.async(fn ->
        Process.sleep(50)
        started_at = System.monotonic_time(:millisecond)

        record =
          LedgerEvents.record!(
            subject_external_id: subject,
            occurred_at: ~U[2026-10-02 08:00:00.000000Z]
          )

        {record, System.monotonic_time(:millisecond) - started_at}
      end)

    first = Task.await(holder, 10_000)
    {second, blocked_ms} = Task.await(waiter, 10_000)

    # The waiter really did wait out the holder's stall:
    assert blocked_ms >= 300

    # Commit order is sequence order: the waiter was assigned only after
    # the holder committed, so its sequence is the next link in the
    # holder's chain.
    assert second.sequence > first.sequence
    assert second.previous_hash == first.hash

    # And the chain agrees:
    us = VerifyChains.verify(Ledger, :us)
    assert us.findings == []
  end

  test "concurrent same-region writers produce unique, chain-ordered sequences", %{
    subject: subject
  } do
    # Eight concurrent writers in one region: the lock serializes
    # assignment, so every row gets a distinct sequence and the chain
    # walks cleanly in sequence order. (With a bare bigserial and
    # inverted commits, a consumer's high-water mark would silently lose
    # a row — the failure mode this test exists to catch.)
    writers =
      for i <- 1..8 do
        Task.async(fn ->
          LedgerEvents.record!(
            subject_external_id: subject,
            occurred_at:
              ~U[2026-10-01 14:03:00.000000Z]
              |> DateTime.add(i, :millisecond)
          )
        end)
      end

    records = Enum.map(writers, &Task.await(&1, 15_000))

    sequences = Enum.map(records, & &1.sequence)
    assert length(Enum.uniq(sequences)) == 8

    assert VerifyChains.verify(Ledger, :us).findings == []
  end
end
