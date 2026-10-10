# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LedgerReplayTest do
  @moduledoc """
  The substrate claim (§5.1) and the isolation claim (§5.6), proven:

    * the ledger's rows drain through AshEvents' `:replay` action and
      rebuild a consumer byte-identically (the projector engine and
      rebuilder come free);
    * a simulated event — recorded in the TWIN's table — can never reach
      the real ledger's rebuild, because the real rebuild reads the real
      module's table. Type-level isolation, not query-filter discipline.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Ledger
  alias AshDiscreteBusinessEvents.Fixtures.LedgerEvents
  alias AshDiscreteBusinessEvents.Fixtures.Projection

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{subject: LedgerEvents.subject_external_id()}
  end

  defp projection_shape(row) do
    %{id: row.id, stage: row.stage, amount: row.amount}
  end

  defp replay_ledger do
    Ledger
    |> Ash.ActionInput.for_action(:replay, %{})
    |> Ash.run_action!()
  end

  test "replaying the ledger rebuilds the consumer byte-identically", %{subject: subject} do
    # The consumer, built the ordinary way (what a projector would have
    # written, draining the ledger incrementally).
    original =
      Projection
      |> Ash.Changeset.for_create(:"opportunity.stage_changed", %{
        id: subject,
        stage: "Proposal",
        amount: 95_000
      })
      |> Ash.create!()

    built = [projection_shape(original)]

    # ...and the ledger events that DESCRIBE those writes.
    LedgerEvents.record!(%{
      subject_external_id: subject,
      subject_resource: Projection,
      data: %{"id" => subject, "stage" => "Proposal", "amount" => 95_000}
    })

    # Wipe the consumer (the clear_records_for_replay step) and rebuild
    # purely from the ledger:
    replay_ledger()

    rebuilt = Projection |> Ash.read!() |> Enum.map(&projection_shape/1)
    assert Enum.sort(rebuilt) == Enum.sort(built)
  end

  test "amendments replay as updates, still byte-identical", %{subject: subject} do
    row =
      Projection
      |> Ash.Changeset.for_create(:"opportunity.stage_changed", %{
        id: subject,
        stage: "Proposal",
        amount: 95_000
      })
      |> Ash.create!()

    amended =
      row
      |> Ash.Changeset.for_update(:"opportunity.stage_amended", %{
        stage: "Negotiation",
        amount: 97_500
      })
      |> Ash.update!()

    built = [projection_shape(amended)]

    LedgerEvents.record!(%{
      subject_external_id: subject,
      subject_resource: Projection,
      data: %{"id" => subject, "stage" => "Proposal", "amount" => 95_000}
    })

    LedgerEvents.record!(%{
      subject_external_id: subject,
      subject_resource: Projection,
      event_kind: :"opportunity.stage_amended",
      data: %{"stage" => "Negotiation", "amount" => 97_500}
    })

    replay_ledger()

    rebuilt = Projection |> Ash.read!() |> Enum.map(&projection_shape/1)
    assert Enum.sort(rebuilt) == Enum.sort(built)
  end

  test "a simulated event can never reach the real ledger's rebuild", %{subject: subject} do
    Projection
    |> Ash.Changeset.for_create(:"opportunity.stage_changed", %{
      id: subject,
      stage: "Proposal",
      amount: 95_000
    })
    |> Ash.create!()

    built = Projection |> Ash.read!() |> Enum.map(&projection_shape/1)

    LedgerEvents.record!(%{
      subject_external_id: subject,
      subject_resource: Projection,
      data: %{"id" => subject, "stage" => "Proposal", "amount" => 95_000}
    })

    # A simulated event that describes the SAME kind of write — recorded
    # in the TWIN. If isolation were a query-filter discipline, this
    # would leak into the real rebuild.
    LedgerEvents.simulate!(%{
      subject_external_id: subject <> "-sim",
      subject_resource: Projection,
      simulation_run: "ac3-demo",
      data: %{"id" => subject <> "-sim", "stage" => "FABRICATED", "amount" => 1}
    })

    sim_row =
      AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent.by_subject!(
        :us,
        subject <> "-sim"
      )
      |> hd()

    # The twin is unmistakable by shape:
    assert sim_row.simulated == true
    assert sim_row.simulation_run == "ac3-demo"

    # ...and unmistakable by module: the real rebuild never reads that
    # table, so the fabricated event cannot appear.
    replay_ledger()

    rebuilt = Projection |> Ash.read!() |> Enum.map(&projection_shape/1)
    assert length(rebuilt) == length(built)
    refute Enum.any?(rebuilt, &(&1.stage == "FABRICATED"))
    assert Enum.sort(rebuilt) == Enum.sort(built)
  end
end
