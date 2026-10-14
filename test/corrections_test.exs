# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.CorrectionsTest do
  @moduledoc """
  Corrections & late-arrival semantics (design §7):

    * `supersedes_event_id` DERIVED at the fold — a mapped fact that
      differs from the ledgered truth AT THE SAME SUBJECT TRUTH POINT
      becomes a superseding event; the original is never rewritten.
    * Projectors receive supersession as data — the temporal projection
      restates at the correction's own truth instant and counts it.
    * Resync-after-cursor-loss: identical → no-op (proven), changed →
      new period + correction event; never duplicates, never silently
      revises.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshDiscreteBusinessEvents.Fixtures.{
    CorpusHost,
    CorpusProjector,
    Ledger,
    MappingVersion,
    PipelineHistory
  }

  alias AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus
  alias AshDiscreteBusinessEvents.Ledger.Corrections
  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  @subject "0065f000000000004"
  @june_stamp ~U[2026-06-01 05:32:48Z]
  @revision_file "run-2026-06.csv"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Repo.delete_all(PipelineHistory)
    Repo.delete_all("bizev_projection_checkpoints")
    Repo.delete_all(MappingVersion)

    start_supervised!(AshOpenLineage.Transport.InMemory)
    AshOpenLineage.Transport.InMemory.clear()
    start_supervised!(FixtureCorpus.Auth)
    FixtureCorpus.Auth.reset()
    start_supervised!(FixtureCorpus.Revisions)
    FixtureCorpus.Revisions.clear()

    :ok
  end

  # ── the register, pure ────────────────────────────────────────────────

  describe "Corrections.classify/4" do
    test "an unseen truth point is :new" do
      register = %Corrections{points: %{}}

      assert Corrections.classify(register, "s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Won"}) ==
               :new
    end

    test "the same point with the same data is :duplicate" do
      register =
        Corrections.put(
          %Corrections{points: %{}},
          "s1",
          ~U[2026-06-01 05:32:48Z],
          %{"stage" => "Won"},
          "evt-1"
        )

      assert Corrections.classify(register, "s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Won"}) ==
               :duplicate
    end

    test "the same point with DIFFERENT data is a correction naming the current truth" do
      register =
        Corrections.put(
          %Corrections{points: %{}},
          "s1",
          ~U[2026-06-01 05:32:48Z],
          %{"stage" => "Won"},
          "evt-1"
        )

      assert {:correction, %{event_id: "evt-1"}} =
               Corrections.classify(register, "s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Lost"})
    end

    test "a second correction supersedes the first — each is the new present" do
      register =
        %Corrections{points: %{}}
        |> Corrections.put("s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Won"}, "evt-1")
        |> Corrections.put("s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Lost"}, "evt-2")

      assert {:correction, %{event_id: "evt-2"}} =
               Corrections.classify(register, "s1", ~U[2026-06-01 05:32:48Z], %{"stage" => "Void"})
    end
  end

  # ── the corrections demo (§8's honest path, continued) ────────────────

  describe "the corrections demo" do
    test "a retroactive revision supersedes — original untouched, projection restates, as-of answers honestly" do
      # ── the original history ──
      {:ok, first} = corpus_import()
      assert first.corrections == 0

      assert CorpusProjector.drain(:us) == first.ledger_events

      original = june_event()
      assert original.data["stage"] == "Closed Won"
      assert original.supersedes_event_id == nil
      original_hash = original.hash

      # The projection's pre-correction truth, and the as-of answer at
      # May-15 (BEFORE the truth point) — captured to prove the
      # correction never rewrites earlier truth.
      value_before = pipeline_value(@subject, nil)
      assert value_before.stage == "Closed Won"

      may_truth = pipeline_value(@subject, ~U[2026-05-15 00:00:00Z])

      # ── the source REWRITES HISTORY: arm the revision fixture ──
      {:ok, revision_rows} = revision_rows()
      FixtureCorpus.arm_revision!(@revision_file, revision_rows)

      # ── the re-import: the cursor-lost full replay ──
      {:ok, second} = corpus_import()

      # Exactly the correction landed: one new raw period (the restated
      # June snapshot row), one new ledger event, everything else folded.
      assert second.landed == 1
      assert second.ledger_events == 1
      assert second.corrections == 1

      # The superseding event: same truth point, new data, pointing at
      # the original.
      correction = superseding_event(original.id)

      assert correction.data["stage"] == "Negotiation"
      assert correction.occurred_at |> DateTime.to_unix() == DateTime.to_unix(@june_stamp)
      assert correction.supersedes_event_id == original.id

      # The ORIGINAL is never rewritten — same row, same data, same hash.
      untouched = Ledger.by_id!(original.id, :us)
      assert untouched.data["stage"] == "Closed Won"
      assert untouched.hash == original_hash

      # The projection restates at the correction's own truth instant and
      # counts the correction.
      assert CorpusProjector.drain(:us) == 1
      restated = pipeline_value(@subject, nil)
      assert restated.stage == "Negotiation"
      assert restated.amount == original.data["amount"]
      assert restated.corrections == 1

      # As-of reads answer honestly on BOTH sides of the correction:
      # before the truth instant, the pre-correction truth stands
      # UNCHANGED (whatever it was); after it, the corrected truth.
      assert pipeline_value(@subject, ~U[2026-05-15 00:00:00Z]).stage == may_truth.stage
      june_truth = pipeline_value(@subject, ~U[2026-06-15 00:00:00Z])
      assert june_truth.stage == "Negotiation"
    end

    test "a correction's truth-point replay folds away — importing the same revision twice is idempotent" do
      {:ok, first} = corpus_import()
      {:ok, revision_rows} = revision_rows()
      FixtureCorpus.arm_revision!(@revision_file, revision_rows)

      {:ok, _} = corpus_import()
      {:ok, third} = corpus_import()

      assert third.landed == 0
      assert third.ledger_events == 0
      assert third.corrections == 0
      assert first.corrections == 0
    end
  end

  # ── resync after cursor loss (§7) ─────────────────────────────────────

  describe "resync after cursor loss" do
    test "identical re-observation is a no-op; drifted content is a correction — never duplicates, never silent" do
      {:ok, first} = corpus_import()
      assert first.ledger_events > 100

      # Cursor loss, the operator shape: the record's cursor-as-data is
      # explicitly reset before the full re-sync.
      record =
        AshDiscreteBusinessEvents.Fixtures.SourceRecord
        |> Ash.Query.filter(external_id == ^@subject and region == :us)
        |> Ash.read_one!(authorize?: false)

      reset = AshDiscreteBusinessEvents.Fixtures.SourceRecord.reset_cursor!(record)
      assert reset.cursor == nil

      # The full re-sync over UNCHANGED snapshots: everything folds.
      {:ok, resync} = corpus_import()
      assert resync.landed == 0
      assert resync.ledger_events == 0

      # Now the source DRIFTS: the June truth is restated.
      {:ok, revision_rows} = revision_rows()
      FixtureCorpus.arm_revision!(@revision_file, revision_rows)

      events_before = length(Ledger.by_region!(:us))

      {:ok, drifted} = corpus_import()

      # EXACTLY the corrections landed: one raw period, one superseding
      # event — no duplicates, no silent revision.
      assert drifted.landed == 1
      assert drifted.ledger_events == 1
      assert drifted.corrections == 1
      assert length(Ledger.by_region!(:us)) == events_before + 1

      # …and the supersession points at the original June truth.
      stamp = DateTime.to_unix(@june_stamp)

      original =
        Ledger.by_subject!(:us, @subject)
        |> Enum.find(
          &(&1.occurred_at |> DateTime.to_unix() == stamp and is_nil(&1.supersedes_event_id))
        )

      correction =
        Ledger.by_subject!(:us, @subject)
        |> Enum.find(&(&1.supersedes_event_id != nil))

      assert correction.supersedes_event_id == original.id
      assert original.data["stage"] == "Closed Won"
      assert correction.data["stage"] == "Negotiation"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp corpus_import do
    FixtureCorpus.import(
      host: CorpusHost,
      source: :salesforce,
      stream: :opportunity,
      source_record: AshDiscreteBusinessEvents.Fixtures.SourceRecord,
      ledger: Ledger,
      mapping_name: :opportunity_stage_changed,
      mapping_version_resource: MappingVersion
    )
  end

  defp revision_rows do
    path =
      Application.app_dir(:ash_discrete_business_events)
      |> Path.join("priv/fixtures/salesforce/corrections/revision-2026-06.csv")

    [header | data] =
      path |> File.read!() |> String.split(["\r\n", "\n"], trim: true) |> Enum.reject(&(&1 == ""))

    keys = String.split(header, ",")

    {:ok, Enum.map(data, fn line -> Enum.zip(keys, String.split(line, ",")) |> Map.new() end)}
  end

  defp june_event do
    stamp = DateTime.to_unix(@june_stamp)

    Ledger.by_subject!(:us, @subject)
    |> Enum.find(&(&1.occurred_at |> DateTime.to_unix() == stamp))
  end

  defp superseding_event(original_id) do
    Ledger.by_subject!(:us, @subject)
    |> Enum.find(&(&1.supersedes_event_id == original_id))
  end

  # The current pipeline value (or the value AS OF an instant).
  defp pipeline_value(subject, nil) do
    PipelineHistory
    |> Ash.Query.filter(subject == ^subject and region == :us)
    |> Ash.read_one!(authorize?: false)
  end

  defp pipeline_value(subject, as_of) do
    PipelineHistory
    |> Ash.Query.filter(subject == ^subject)
    |> Ash.Query.as_of(as_of)
    |> Ash.read_one!(authorize?: false)
  end
end
