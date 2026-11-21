# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SimulationProjectionTest do
  @moduledoc """
  The `simulation_projection: true` contract: a projector draining the
  simulation twin can declare itself a simulation projection, whose grain
  must include the simulation run — so two runs give two projection rows
  instead of overwriting each other (the checkpoints are already per
  run; only the rows collided).

  * Compile time: the projection resource's `grain_fields` must include
    `:simulation_run` and the resource must carry the attribute — the
    module refuses to compile otherwise.
  * Drain time: `drain_simulation/3` verifies every event's grain names
    the event's own run (a wrong grain is a declaration bug — raise,
    never DeadLetter), and the real-ledger `drain/2` refuses outright.
  """

  use ExUnit.Case, async: false

  alias AshDiscreteBusinessEvents.Fixtures.{
    CorpusProjector,
    LedgerEvents,
    SimProjectionProjector,
    SimRunProjection
  }

  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  @kind :opportunity_stage_changed

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Repo.delete_all(SimRunProjection)
    Repo.delete_all("bizev_projection_checkpoints")

    :ok
  end

  defp sim_event(subject, run, stage) do
    LedgerEvents.simulate!(
      event_kind: @kind,
      subject_external_id: subject,
      simulation_run: run,
      occurred_at: ~U[2026-10-01 10:00:00Z],
      data: %{"stage" => stage, "amount" => 90_000}
    )
  end

  defp drain_simulation(projector, run, region), do: projector.drain_simulation(run, region)

  # Run labels are unique per test: the twin's table holds every run.
  defp run(label), do: "sp-#{label}-#{System.unique_integer([:positive])}"

  defp rows do
    SimRunProjection
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&{&1.simulation_run, &1.subject})
  end

  describe "the flag" do
    test "the option generates __simulation_projection__/0, false by default" do
      assert SimProjectionProjector.__simulation_projection__() == true
      assert CorpusProjector.__simulation_projection__() == false
    end
  end

  describe "two runs, two rows" do
    test "same subject, same kind: each run gets its own row with its own values" do
      subject = LedgerEvents.subject_external_id()
      alpha = run("alpha")
      beta = run("beta")

      sim_event(subject, alpha, "Won")
      sim_event(subject, beta, "Lost")

      assert SimProjectionProjector.drain_simulation(alpha, :us) == 1
      assert SimProjectionProjector.drain_simulation(beta, :us) == 1

      assert length(rows()) == 2

      alpha_row = Enum.find(rows(), &(&1.simulation_run == alpha))
      beta_row = Enum.find(rows(), &(&1.simulation_run == beta))

      assert alpha_row && beta_row
      assert alpha_row.subject == subject
      assert beta_row.subject == subject
      assert alpha_row.stage == "Won"
      assert beta_row.stage == "Lost"
    end

    test "re-draining a run is idempotent — the cursor, no extra row" do
      subject = LedgerEvents.subject_external_id()
      alpha = run("alpha")

      sim_event(subject, alpha, "Won")

      assert SimProjectionProjector.drain_simulation(alpha, :us) == 1
      assert SimProjectionProjector.drain_simulation(alpha, :us) == 0
      assert length(rows()) == 1
    end
  end

  describe "the compile-time verifier" do
    test "a resource whose grain_fields lack :simulation_run refuses to compile the projector" do
      # PipelineHistory's grain_fields are [:region, :subject] — no run
      # field, so a simulation projection over it cannot name two rows.
      assert_raise ArgumentError, ~r/must include :simulation_run/, fn ->
        Code.compile_string("""
        defmodule #{inspect(__MODULE__)}.NoRunFieldProjector do
          use AshDiscreteBusinessEvents.Projections,
            name: "sim_projection_no_run_field_v1",
            event_log: AshDiscreteBusinessEvents.Fixtures.Ledger,
            projection_resource: AshDiscreteBusinessEvents.Fixtures.PipelineHistory,
            simulation_projection: true

          grain(fn event -> %{region: event.region, subject: event.record_id} end)
        end
        """)
      end
    end
  end

  describe "the drain-time grain check" do
    test "a grain fn omitting simulation_run raises at drain_simulation, writes nothing" do
      # The resource has the field (so this compiles), but the grain fn
      # never names the run — a declaration bug, caught per batch before
      # any event is processed.
      projector =
        case Code.compile_string("""
             defmodule #{inspect(__MODULE__)}.NoRunInGrainProjector do
               use AshDiscreteBusinessEvents.Projections,
                 name: "sim_projection_no_run_grain_v1",
                 event_log: AshDiscreteBusinessEvents.Fixtures.Ledger,
                 projection_resource: AshDiscreteBusinessEvents.Fixtures.SimRunProjection,
                 simulation_projection: true

               grain(fn event -> %{region: event.region, subject: event.record_id} end)

               project("opportunity_stage_changed", fn event ->
                 [{:set, :stage, event.data["stage"]}]
               end)
             end
             """) do
          [{module, _beam}] -> module
        end

      subject = LedgerEvents.subject_external_id()
      alpha = run("alpha")
      sim_event(subject, alpha, "Won")

      assert_raise ArgumentError, ~r/simulation_run/, fn ->
        drain_simulation(projector, alpha, :us)
      end

      # Raised before processing: no projection row, and the checkpoint
      # never advanced past the event.
      assert rows() == []
    end
  end

  describe "the twin-only drain" do
    test "drain/2 on a simulation projection raises" do
      assert_raise ArgumentError, ~r/SimulationEvent twin/, fn ->
        SimProjectionProjector.drain(:us)
      end
    end
  end
end
