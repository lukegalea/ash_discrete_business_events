# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SimulationIsolationTest do
  @moduledoc """
  SIM-NAMESPACE-ISOLATION — the three acceptance criteria, assembled.
  This file is the ticket's regression suite; its passing is the
  closure statement.

    * **AC-1 (integration)** — a simulated run's events exist in the
      twin; a real projector's rebuild-from-zero never reads them, so
      none of the simulated events appear in its resulting state.
    * **AC-2 (unit/integration)** — the isolation extends to the
      projector/checkpoint CACHE keying: a simulation drain's
      checkpoints (`sim:<name>.<region>:<run>`) can never collide with
      real-drain checkpoints (`<name>.<region>`) on the same projector
      and region, and two simulation runs never share one.
    * **AC-3 (the labeling contract)** — sim rows are unmistakable by
      SHAPE (`simulated: true` + `simulation_run`, set at record time)
      and by TABLE (the twin; a real-ledger read can never contain one);
      `AshDiscreteBusinessEvents.simulation_runs/1` is the supported
      read for any surface that labels them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshDiscreteBusinessEvents.Fixtures.{
    CorpusProjector,
    Ledger,
    LedgerEvents,
    PipelineHistory
  }

  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  @projector "corpus_pipeline_history_v1"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Repo.delete_all(PipelineHistory)
    Repo.delete_all("bizev_projection_checkpoints")

    :ok
  end

  # The kind the corpus projector routes (its mapping name).
  @kind :opportunity_stage_changed

  defp real_event(subject, stage) do
    LedgerEvents.record!(
      event_kind: @kind,
      subject_external_id: subject,
      occurred_at: ~U[2026-10-01 10:00:00Z],
      data: %{"stage" => stage, "amount" => 90_000}
    )
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

  defp checkpoints do
    Repo.all(
      from(cp in "bizev_projection_checkpoints",
        select: %{name: cp.projection_name, seen: cp.last_seen_event_id}
      )
    )
    |> Enum.filter(&String.contains?(&1.name, @projector))
  end

  defp stages do
    PipelineHistory |> Repo.all() |> Enum.map(& &1.stage) |> Enum.sort()
  end

  # ── AC-1 ───────────────────────────────────────────────────────────────

  describe "AC-1: the real rebuild never reads simulated events" do
    test "a rebuild-from-zero of the real projector reproduces only real truth" do
      real = LedgerEvents.subject_external_id()
      real_event(real, "Proposal")

      # A simulated event describing the SAME kind of write, with a
      # stage that could only have come from fabrication.
      sim_event(LedgerEvents.subject_external_id(), "ac1-fabricator", "FABRICATED")

      # The real drain (live and rebuilt-from-zero below) reads the REAL
      # ledger's feed — structurally the twin is another table.
      assert CorpusProjector.drain(:us) == 1
      assert stages() == ["Proposal"]

      # Rebuild from zero: wipe the state AND the cursor, re-drain.
      Repo.delete_all(PipelineHistory)
      Repo.delete_all("bizev_projection_checkpoints")

      assert CorpusProjector.drain(:us) == 1
      assert stages() == ["Proposal"]
      refute Enum.any?(stages(), &(&1 == "FABRICATED"))
    end
  end

  # ── AC-2 ───────────────────────────────────────────────────────────────

  describe "AC-2: the checkpoint/cache namespace" do
    test "sim and real drains on the same projector + region never alias" do
      real = LedgerEvents.subject_external_id()
      real_event(real, "Proposal")

      sim_a1 = LedgerEvents.subject_external_id()
      sim_a2 = LedgerEvents.subject_external_id()
      sim_event(sim_a1, "whatif-alpha", "Won")
      sim_event(sim_a2, "whatif-alpha", "Negotiation")

      sim_b = LedgerEvents.subject_external_id()
      sim_event(sim_b, "whatif-beta", "Lost")

      # Three drains, one projector name, one region, three cursors.
      assert CorpusProjector.drain(:us) == 1
      assert CorpusProjector.drain_simulation("whatif-alpha", :us) == 2
      assert CorpusProjector.drain_simulation("whatif-beta", :us) == 1

      cps = checkpoints()
      assert length(cps) == 3

      real_cp = Enum.find(cps, &(&1.name == "#{@projector}.us"))
      alpha_cp = Enum.find(cps, &(&1.name == "sim:#{@projector}.us:whatif-alpha"))
      beta_cp = Enum.find(cps, &(&1.name == "sim:#{@projector}.us:whatif-beta"))

      # Distinct rows, each advanced to its OWN stream's tail.
      assert real_cp && alpha_cp && beta_cp
      assert real_cp.seen != alpha_cp.seen
      assert alpha_cp.seen != beta_cp.seen

      # Each cursor resumes independently: the real drain is exhausted
      # (its feed has nothing new), and so is each sim drain.
      assert CorpusProjector.drain(:us) == 0
      assert CorpusProjector.drain_simulation("whatif-alpha", :us) == 0
      assert CorpusProjector.drain_simulation("whatif-beta", :us) == 0
    end

    test "a real rebuild-from-zero never consumes the sim drain's stream — AC-1 at the cache layer" do
      real = LedgerEvents.subject_external_id()
      real_event(real, "Proposal")

      sim_event(LedgerEvents.subject_external_id(), "ac2-whatif", "FABRICATED")

      # The sim drain runs FIRST — its checkpoint advances past the
      # fabricated event. The real drain's checkpoint is untouched.
      assert CorpusProjector.drain_simulation("ac2-whatif", :us) == 1
      assert CorpusProjector.drain(:us) == 1

      # Rebuild the REAL projector from zero: wipe the state and the
      # real cursor only — the sim cursor stands.
      Repo.delete_all(PipelineHistory)

      Repo.delete_all(
        from(cp in "bizev_projection_checkpoints",
          where: cp.projection_name == ^"#{@projector}.us"
        )
      )

      assert CorpusProjector.drain(:us) == 1

      # The rebuilt state contains ONLY real truth: the fabricated event
      # was never in the real feed the rebuild reads, and the sim drain's
      # cursor never leaked into the real rebuild's cursor.
      assert stages() == ["Proposal"]
    end
  end

  # ── AC-3 ───────────────────────────────────────────────────────────────

  describe "AC-3: the labeling contract" do
    test "simulation_runs/1 surfaces which runs produced which rows; rows labeled by shape" do
      sim_event(LedgerEvents.subject_external_id(), "ac3-alpha", "Won")
      sim_event(LedgerEvents.subject_external_id(), "ac3-alpha", "Lost")
      sim_event(LedgerEvents.subject_external_id(), "ac3-beta", "Negotiation")

      # The supported read accepts the ledger or the twin directly.
      runs = AshDiscreteBusinessEvents.simulation_runs(Ledger)
      assert runs == AshDiscreteBusinessEvents.simulation_runs(Ledger.SimulationEvent)

      assert length(runs) == 2

      alpha = Enum.find(runs, &(&1.simulation_run == "ac3-alpha"))
      beta = Enum.find(runs, &(&1.simulation_run == "ac3-beta"))

      assert alpha.events == 2
      assert alpha.subjects == 2
      assert beta.events == 1
      assert beta.subjects == 1

      # Every twin row is labeled BY SHAPE — set at record time.
      for row <- Ash.read!(Ledger.SimulationEvent, authorize?: false) do
        assert row.simulated == true
        assert row.simulation_run in ["ac3-alpha", "ac3-beta"]
      end

      # …and structurally nowhere else: the sim subjects do not exist in
      # the real ledger, and the twin's table is not the real table.
      sim_subject = sim_event(LedgerEvents.subject_external_id(), "ac3-gamma", "Won")
      assert Ledger.by_subject!(:us, sim_subject.subject_external_id) == []
    end
  end
end
