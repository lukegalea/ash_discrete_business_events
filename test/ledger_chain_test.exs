# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LedgerChainTest do
  @moduledoc """
  The per-region hash chain: clean verification across regions, tamper
  detection (:altered), removal detection (:broken_link), and the
  twin's chain being its own.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Ledger
  alias AshDiscreteBusinessEvents.Fixtures.LedgerEvents
  alias AshDiscreteBusinessEvents.Ledger.VerifyChains

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{subject: LedgerEvents.subject_external_id()}
  end

  test "recording leaves every touched region's chain clean", %{subject: subject} do
    LedgerEvents.record!(subject_external_id: subject)
    LedgerEvents.record!(subject_external_id: subject, region: :ca, residency_tag: "ca")
    LedgerEvents.record!(subject_external_id: subject)

    results = VerifyChains.verify_all(Ledger)
    assert VerifyChains.clean?(results)

    us = Enum.find(results, &(&1.region == :us))
    assert us.checked >= 2
    assert us.findings == []
  end

  test "tampering a row is detected (:altered)", %{subject: subject} do
    e1 = LedgerEvents.record!(subject_external_id: subject)

    LedgerEvents.record!(
      subject_external_id: subject,
      occurred_at: ~U[2026-10-02 08:00:00.000000Z]
    )

    repo = AshDiscreteBusinessEvents.Test.Repo

    # An operator with psql: drop the immutability trigger, edit quietly,
    # put it back. The chain still notices — that is the point of doing
    # both.
    repo.query!("ALTER TABLE ledger_events DISABLE TRIGGER bizev_ledger_events_immutable")

    repo.query!(
      "UPDATE ledger_events SET data = data || '{\"tampered\": true}' WHERE id = $1",
      [Ecto.UUID.dump!(e1.id)]
    )

    repo.query!("ALTER TABLE ledger_events ENABLE TRIGGER bizev_ledger_events_immutable")

    us = VerifyChains.verify(Ledger, :us)
    refute us.findings == []

    assert Enum.any?(us.findings, &(&1.problem == :altered and &1.id == e1.id))
  end

  test "removing a row breaks the link (:broken_link)", %{subject: subject} do
    e1 = LedgerEvents.record!(subject_external_id: subject)

    e2 =
      LedgerEvents.record!(
        subject_external_id: subject,
        occurred_at: ~U[2026-10-02 08:00:00.000000Z]
      )

    repo = AshDiscreteBusinessEvents.Test.Repo
    repo.query!("ALTER TABLE ledger_events DISABLE TRIGGER bizev_ledger_events_immutable")
    repo.query!("DELETE FROM ledger_events WHERE id = $1", [Ecto.UUID.dump!(e1.id)])
    repo.query!("ALTER TABLE ledger_events ENABLE TRIGGER bizev_ledger_events_immutable")

    us = VerifyChains.verify(Ledger, :us)

    assert Enum.any?(
             us.findings,
             &(&1.problem == :broken_link and &1.id == e2.id)
           )
  end

  test "the simulation twin's chain is its own", %{subject: subject} do
    LedgerEvents.simulate!(subject_external_id: subject)
    LedgerEvents.simulate!(subject_external_id: subject)

    results = VerifyChains.verify_all(AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent)
    assert VerifyChains.clean?(results)
  end
end
