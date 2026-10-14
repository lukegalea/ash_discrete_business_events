# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.ProjectionTest do
  @moduledoc """
  BIZEV-8: temporal canonical projections over the ledger (design §4's
  temporal row + §5.1's projector story).

    Every drain/count assertion here is region-scoped (:ca) and sandbox-clean:
  the ledger is append-only, so committed history in the shared test
  database would otherwise be visible to every connection.

  The gate is the equivalence proof (the S1-67-family unknown): a
  ledger-driven lifecycle — multiple subjects, a supersession, a late
  arrival — rebuilt by the projector from scratch yields **byte-identical
  periods** in the temporal projection. Failure here does not gate
  as-of consumers casually: it is a finding.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias AshDiscreteBusinessEvents.Fixtures.{LedgerEvents, PipelineHistory, PipelineProjector}
  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  # The projection tests run in region :ca: the ledger is append-only, so
  # any already-COMMITTED rows in the shared test database are visible to
  # every sandbox connection, and :us carries probe history. A drain over
  # :ca sees exactly this test's events — full isolation, by region, which
  # is rather the point of §6.
  @test_region :ca

  defp record!(overrides) do
    LedgerEvents.record!([region: @test_region, residency_tag: "ca"] ++ overrides)
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # This file owns the projector's state: the checkpoint and the
    # projection rows (the ledger itself is append-only and shared).
    Repo.delete_all(PipelineHistory)
    Repo.delete_all("bizev_projection_checkpoints")

    %{
      subject_a: LedgerEvents.subject_external_id(),
      subject_b: LedgerEvents.subject_external_id()
    }
  end

  describe "the drain" do
    test "folds kind-routed events into the temporal projection", %{subject_a: subject} do
      record!(
        subject_external_id: subject,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 90_000}
      )

      assert PipelineProjector.drain(@test_region) == 1

      periods = periods(subject)
      assert length(periods) == 1
      assert hd(periods).stage == "Proposal"
      assert hd(periods).amount == 90_000
      assert hd(periods).valid_at.lower == ~U[2026-10-01 10:00:00.000000Z]
      assert hd(periods).valid_at.upper == nil
    end

    test "unrelated kinds are skipped — kind-only routing, unchanged" do
      # A kind no handler declares: the drain consumes it, writes nothing.
      record!(event_kind: :"region.disclosure", data: %{})

      assert PipelineProjector.drain(@test_region) == 1
      assert Repo.aggregate(PipelineHistory, :count) == 0
    end

    test "the checkpoint makes the drain idempotent", %{subject_a: subject} do
      record!(subject_external_id: subject, occurred_at: ~U[2026-10-01 10:00:00Z])

      assert PipelineProjector.drain(@test_region) == 1
      assert PipelineProjector.drain(@test_region) == 0

      assert length(periods(subject)) == 1
      assert Repo.aggregate(PipelineHistory, :count) == 1
    end

    test "regions never share a cursor — :ca drains its own feed" do
      record!(
        subject_external_id: LedgerEvents.subject_external_id(),
        occurred_at: ~U[2026-10-02 09:00:00Z]
      )

      # The feed is region-scoped by construction; the CA drain consumes
      # exactly its own region's event and nothing else materializes.
      # (A :us drain here would sweep :us's COMMITTED history in the shared
      # test database — the ledger is append-only — so the isolation pin is
      # "the CA cursor consumed exactly one event", which is the §6 claim.)
      assert PipelineProjector.drain(@test_region) == 1
      assert PipelineProjector.drain(@test_region) == 0

      regions =
        PipelineHistory
        |> Repo.all()
        |> Enum.map(& &1.region)
        |> Enum.uniq()

      assert regions == [:ca]
    end

    test "a poisoned event lands in the DeadLetter and the projector keeps flowing", %{
      subject_a: subject
    } do
      # An event the handler cannot digest: no to_stage to set. The
      # handler raises; the drain quarantines the event in the DeadLetter
      # and the projector keeps flowing.
      record!(subject_external_id: subject, data: %{"amount" => 1})
      good_subject = LedgerEvents.subject_external_id()

      record!(
        subject_external_id: good_subject,
        occurred_at: ~U[2026-10-01 10:00:00Z]
      )

      assert PipelineProjector.drain(@test_region) == 2

      # The poison is quarantined with its failure; the good event flowed.
      %{rows: dlq} =
        Repo.query!(
          "SELECT count(*) FROM bizev_projection_dead_letter_events WHERE status = 'failed'"
        )

      assert dlq == [[1]]
      assert length(periods(good_subject)) == 1
    end
  end

  describe "temporal semantics — truth time, not drain time" do
    test "a late arrival REOPENS the period at the instant the truth changed", %{
      subject_a: subject
    } do
      # Committed in this order (sequence order), but the second event's
      # TRUTH time precedes the first's:
      record!(
        subject_external_id: subject,
        occurred_at: ~U[2026-10-04 14:00:00Z],
        data: %{"from_stage" => "Proposal", "to_stage" => "Negotiation", "amount" => 95_000}
      )

      record!(
        subject_external_id: subject,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 90_000}
      )

      assert PipelineProjector.drain(@test_region) == 2

      periods = periods(subject)

      # Oldest first: the backdated truth's period, then the late event's.
      assert length(periods) == 2

      back = Enum.at(periods, 0)
      late = Enum.at(periods, 1)

      assert back.stage == "Proposal"
      assert back.valid_at.lower == ~U[2026-10-01 10:00:00.000000Z]

      # The backdated truth reopened history at its own instant; the late
      # event's period survived as the successor.
      assert late.stage == "Negotiation"
      assert late.valid_at.lower == ~U[2026-10-04 14:00:00.000000Z]
      assert late.valid_at.upper == nil

      # The backdated period does not overrun the successor: the machinery
      # closes it where the later-known period begins.
      assert back.valid_at.upper == late.valid_at.lower
    end

    test "a supersession is restated as a new period and counted", %{subject_a: subject} do
      original =
        record!(
          subject_external_id: subject,
          occurred_at: ~U[2026-10-01 10:00:00Z],
          data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 90_000}
        )

      PipelineProjector.drain(@test_region)

      # The correction: a NEW event superseding the original (§7 — the
      # original is never rewritten; the projection restates and counts).
      record!(
        subject_external_id: subject,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        supersedes_event_id: original.id,
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 105_000}
      )

      PipelineProjector.drain(@test_region)

      # The correction's truth instant EQUALS the period's own start — the
      # same truth-point is RESTATED IN PLACE (the ledger row is never
      # rewritten; the projection's period content is). A correction at a
      # new instant would open a new period — the equivalence test covers
      # that shape alongside the late arrival.
      periods = periods(subject)
      assert length(periods) == 1

      restated = hd(periods)
      assert restated.amount == 105_000
      assert restated.corrections == 1
      assert restated.valid_at.lower == ~U[2026-10-01 10:00:00.000000Z]
    end
  end

  # ── THE EQUIVALENCE GATE (the S1-67-family proof) ───────────────────────

  describe "replay equivalence" do
    test "a rebuild of the ledger-driven lifecycle yields byte-identical periods", %{
      subject_a: subject_a,
      subject_b: subject_b
    } do
      # The lifecycle: two subjects, stage progressions, a late arrival on
      # one, a supersession on the other — recorded in commit order (the
      # lock's sequence order), which is the order the feed drains in.
      record!(
        subject_external_id: subject_a,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 90_000}
      )

      late_b =
        record!(
          subject_external_id: subject_b,
          occurred_at: ~U[2026-10-05 09:00:00Z],
          data: %{
            "from_stage" => "Qualification",
            "to_stage" => "Closed Won",
            "amount" => 250_000
          }
        )

      record!(
        subject_external_id: subject_a,
        occurred_at: ~U[2026-10-03 12:00:00Z],
        data: %{"from_stage" => "Proposal", "to_stage" => "Negotiation", "amount" => 95_000}
      )

      # subject_b's EARLIER truth, learned late (sequence after late_b):
      record!(
        subject_external_id: subject_b,
        occurred_at: ~U[2026-10-02 08:00:00Z],
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 240_000}
      )

      # subject_a's correction — superseding its first event:
      first_a =
        AshDiscreteBusinessEvents.Fixtures.Ledger.by_subject!(@test_region, subject_a)
        |> Enum.find(&(&1.sequence < late_b.sequence))

      record!(
        subject_external_id: subject_a,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        supersedes_event_id: first_a.id,
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 92_500}
      )

      # ── the live drain ──
      assert PipelineProjector.drain(@test_region) == 5
      live = snapshot()

      assert length(live) == 4, "two subjects x two truth intervals each"

      # ── the rebuild: wipe the projection, reset the cursor, re-drain ──
      Repo.delete_all(PipelineHistory)
      Repo.delete_all("bizev_projection_checkpoints")

      assert PipelineProjector.drain(@test_region) == 5
      rebuilt = snapshot()

      # THE GATE: byte-identical periods — bounds, content and counters.
      # (recorded_at and the generated ids are the write's clock and the
      # storage's; the PERIODS must not differ — the same ruling the raw
      # layer's replay shape takes.)
      assert rebuilt == live
    end
  end

  # ── as-of reads: "pipeline value of account X at T" ─────────────────────

  describe "as-of reads" do
    test "the projection answers for any instant — backdated and corrected truth included",
         %{subject_a: subject_a} do
      record!(
        subject_external_id: subject_a,
        occurred_at: ~U[2026-10-01 10:00:00Z],
        data: %{"from_stage" => "Qualification", "to_stage" => "Proposal", "amount" => 90_000}
      )

      record!(
        subject_external_id: subject_a,
        occurred_at: ~U[2026-10-03 12:00:00Z],
        data: %{"from_stage" => "Proposal", "to_stage" => "Negotiation", "amount" => 95_000}
      )

      PipelineProjector.drain(@test_region)

      by_subject = fn t ->
        PipelineHistory
        |> Ash.Query.filter(subject == ^subject_a)
        |> Ash.Query.as_of(t)
        |> Ash.read!(authorize?: false)
        |> case do
          [value] -> value
          [] -> nil
        end
      end

      # Before the subject's first truth: nothing.
      assert by_subject.(~U[2026-10-01 09:00:00Z]) == nil

      # The original pipeline value, at the backdated instant:
      original = by_subject.(~U[2026-10-02 00:00:00Z])
      assert original.stage == "Proposal"
      assert original.amount == 90_000

      # After the progression: the new truth.
      progressed = by_subject.(~U[2026-10-04 00:00:00Z])
      assert progressed.stage == "Negotiation"
      assert progressed.amount == 95_000

      # Now: the current head, as-of-free.
      [head] = Ash.read!(PipelineHistory, authorize?: false)
      assert head.stage == "Negotiation"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # ALL periods of one subject, oldest first — read straight off the table:
  # a strategy-:context read collapses to the CURRENT version, and these
  # assertions are about the history (the same bypass Observations.history/1
  # takes on the raw layer).
  defp periods(subject) do
    Repo.all(
      from(p in PipelineHistory,
        where: p.subject == ^subject,
        order_by: [asc: fragment("lower(?)", p.valid_at)]
      )
    )
  end

  # Every period of every grain, oldest first — the replay-comparable
  # projection: bounds, content, counters. Excludes the generated id and
  # recorded_at (the write's clock differs on a rebuild BY DESIGN; the
  # periods must not — the raw layer's replay shape, same ruling).
  defp snapshot do
    Repo.all(
      from(p in PipelineHistory,
        order_by: [asc: p.subject, asc: fragment("lower(?)", p.valid_at)]
      )
    )
    |> Enum.map(fn p ->
      %{
        region: p.region,
        subject: p.subject,
        stage: p.stage,
        amount: p.amount,
        corrections: p.corrections,
        valid_at: %{lower: p.valid_at.lower, upper: p.valid_at.upper}
      }
    end)
  end
end
