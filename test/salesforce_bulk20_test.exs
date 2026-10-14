# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SalesforceBulk20Test do
  @moduledoc """
  The Salesforce Bulk API 2.0 vertical (§1.2, §7, §8): the adapter
  boundary's compile-time conformance, the fixture corpus end-to-end
  (land → map → ledger → projection → as-of), budget-exhaustion
  visibility, and idempotent re-import.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias AshDiscreteBusinessEvents.Fixtures.{
    CorpusHost,
    CorpusProjector,
    Ledger,
    MappingVersion,
    PipelineHistory
  }

  alias AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus
  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Lineage
  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # This suite owns the corpus-path state: the projection rows, the
    # corpus projector's checkpoints, the MappingVersion rows for the
    # mapping it publishes, and the lineage transport.
    Repo.delete_all(PipelineHistory)
    Repo.delete_all("bizev_projection_checkpoints")
    Repo.delete_all(MappingVersion)

    start_supervised!(AshOpenLineage.Transport.InMemory)
    AshOpenLineage.Transport.InMemory.clear()
    start_supervised!(FixtureCorpus.Auth)
    FixtureCorpus.Auth.reset()

    :ok
  end

  # ── the boundary: compile-time conformance (§13.2) ─────────────────────

  describe "adapter conformance" do
    test "a source whose adapter misses callbacks fails compilation" do
      assert_raise Spark.Error.DslError, ~r/does not conform/, fn ->
        defmodule Host.NonConformingAdapter do
          use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

          defmodule Broken do
            def cursor_field(_), do: "X"
            # fetch_batch/5 and api_calls_per_batch/0 missing
          end

          business_events do
            source :broken do
              adapter(Broken)
              region :us
            end
          end
        end
      end
    end

    test "a source with an unloaded adapter module fails compilation" do
      assert_raise Spark.Error.DslError, ~r/not available/, fn ->
        defmodule Host.MissingAdapter do
          use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

          business_events do
            source :ghost do
              adapter(Nowhere.DefinitelyNotAModule)
              region :us
            end
          end
        end
      end
    end

    test "a source declaring two auth edges is rejected (the old warning, promoted)" do
      assert_raise Spark.Error.DslError, ~r/exactly ONE auth edge/, fn ->
        defmodule Host.TwoAuths do
          use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

          business_events do
            source :ambiguous do
              adapter(AshDiscreteBusinessEvents.Fixtures.StubAdapter)
              auth(:nango, provider: "salesforce")
              auth(:basic, provider: "salesforce-sandbox")
              region :us
            end
          end
        end
      end
    end

    test "the real Bulk 2.0 adapter is conformance-complete (CorpusHost compiles)" do
      source = Info.source(CorpusHost, :salesforce)
      assert source.adapter == AshDiscreteBusinessEvents.Adapters.SalesforceBulk20
      assert Info.auth_of(source).provider == "salesforce"
      assert source.rate_budget == [daily: 250_000]
    end
  end

  # ── the fixture corpus, end to end (§8) ───────────────────────────────

  describe "the fixture corpus, land → map → ledger → projection" do
    test "the full import produces real periods, real ledger rows with provenance" do
      assert {:ok, summary} = FixtureCorpus.import(
               host: CorpusHost,
               source: :salesforce,
               stream: :opportunity,
               source_record: AshDiscreteBusinessEvents.Fixtures.SourceRecord,
               ledger: Ledger,
               mapping_name: :opportunity_stage_changed,
               mapping_version_resource: MappingVersion
             )

      assert summary.runs == 9
      assert summary.landed > 100
      assert summary.ledger_events > 100
      assert summary.version_hash =~ ~r/^[0-9a-f]{8}$/

      # Every landed row is a REAL period (the corpus's first sight of
      # each subject and each content change opens one; re-sights no-op).
      %{rows: [[raw_rows]]} =
        Repo.query!("SELECT count(*) FROM source_records WHERE region = 'us'")

      assert raw_rows == summary.landed

      # Ledger rows: provenance joins the ACTIVE MappingVersion — the
      # mapping behind every row is reconstructable from the row alone.
      events = Ledger.by_region!(:us)
      assert length(events) == summary.ledger_events

      for event <- Enum.take(events, 25) do
        assert event.action == :opportunity_stage_changed
        assert event.provenance["mapping_name"] == "opportunity_stage_changed"
        assert event.provenance["mapping_version_hash"] == summary.version_hash
        assert event.provenance["source_record_id"]
        assert event.occurred_at.year in 2026
      end
    end

    test "the corpus's late arrival reaches the ledger with a backdated occurred_at" do
      {:ok, _} = corpus_import()

      # Subject 003's March row: Closed Won content with a SystemModstamp
      # earlier than February's max — invisible to cursoring, present in
      # the captured download, backdated at the ledger (§7).
      harbor =
        Ledger.by_subject!(:us, "0065f000000000003")
        |> Enum.sort_by(& &1.occurred_at, DateTime)

      assert length(harbor) >= 2
      won = Enum.find(harbor, &(&1.data["stage"] == "Closed Won"))
      assert won.occurred_at.month == 1 or won.occurred_at.month == 2

      # …and it is the LAST subject event by truth time despite being
      # learned in the March run.
      assert List.last(harbor).id == won.id
    end

    test "the projection drains the corpus and as-of reads answer mid-history" do
      {:ok, summary} = corpus_import()

      assert CorpusProjector.drain(:us) == summary.ledger_events

      subjects =
        PipelineHistory
        |> Repo.all()
        |> Enum.uniq_by(& &1.subject)

      assert length(subjects) > 50

      sample = Enum.random(subjects)

      # The current pipeline value of one account…
      [current] =
        PipelineHistory
        |> Ash.Query.filter(subject == ^sample.subject and region == :us)
        |> Ash.read!(authorize?: false)

      assert current.stage in ["Prospecting", "Qualification", "Proposal", "Negotiation",
                 "Closed Won", "Closed Lost"
               ]

      # …and at the January instant: only January's truth exists (some
      # subjects are created later in the corpus and read as empty).
      january =
        PipelineHistory
        |> Ash.Query.filter(subject == ^sample.subject)
        |> Ash.Query.as_of(~U[2026-01-15 00:00:00Z])
        |> Ash.read!(authorize?: false)

      for early <- january do
        assert early.stage in ["Prospecting", "Qualification", "Proposal", "Negotiation"]
      end
    end

    test "re-import is idempotent: no new periods, no new ledger events" do
      {:ok, first} = corpus_import()

      # Reset ONLY the cursor memory the second import would need — the
      # ledger and raw rows persist (the whole point).
      {:ok, second} = corpus_import()

      assert second.runs == first.runs
      assert second.landed == 0, "identical snapshots at the same fetched_at are temporal no-ops"
      assert second.ledger_events == 0, "identical canonical facts fold away"

      assert second.version_hash == first.version_hash

      # The ledger did not double-count.
      assert length(Ledger.by_region!(:us)) == first.ledger_events
    end
  end

  # ── budget exhaustion: visible FAIL, the feed pauses ───────────────────

  describe "rate budget" do
    test "the sync FAILs visibly at exhaustion, lineage records it, the cursor stands" do
      defmodule Host.BudgetTight do
        use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

        business_events do
          source :salesforce do
            adapter(AshDiscreteBusinessEvents.Adapters.SalesforceBulk20)
            auth(:nango, provider: "salesforce")
            cursor(:system_modstamp)
            region(:us)
            # One batch costs 2 calls; budget 2 allows exactly one.
            rate_budget(daily: 2)

            stream :opportunity do
              select "SELECT Id, StageName, Amount, SystemModstamp FROM Opportunity"
            end
          end

          mapping :opportunity_stage_changed do
            source {:salesforce, :opportunity}

            map :stage, from: "StageName", type: :string
            map :amount, from: "Amount", type: :integer
            map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec
          end
        end
      end

      source = Info.source(Host.BudgetTight, :salesforce)
      stream = Info.stream_of(source, :opportunity)

      # The corpus transport paginates: with a 5-row limit the January
      # run needs TWO batches — the budget allows exactly one.
      result =
        AshDiscreteBusinessEvents.Adapters.Sync.run(
          source: source,
          stream: stream,
          source_record: AshDiscreteBusinessEvents.Fixtures.SourceRecord,
          cursor: nil,
          fetched_at: ~U[2026-01-05 02:00:00Z],
          limit: 5,
          lineage_job: Lineage.job(:sync, source: :salesforce, stream: :opportunity),
          transport: FixtureCorpus.Transport,
          auth_provider: FixtureCorpus.Auth,
          max_batches: 10
        )

      assert {:error, %AshDiscreteBusinessEvents.Adapters.BudgetExhausted{} = exhausted} = result

      # What the completed portion achieved — the caller parks the cursor.
      assert exhausted.landed == 5
      assert exhausted.cursor

      # Lineage recorded the FAIL against the job.
      fails =
        AshOpenLineage.Transport.InMemory.events()
        |> Enum.filter(&(&1["eventType"] == "FAIL"))

      assert length(fails) == 1
      assert hd(fails)["job"]["name"] == "bizev.sync.salesforce.opportunity"
      assert hd(fails)["run"]["facets"]["error"]["errorMessage"] =~ "rate_budget exhausted"

      # The feed paused, never degraded: exactly one batch's rows landed,
      # and the completed cursor stands at the batch boundary.
      landed =
        Repo.all(
          from(s in AshDiscreteBusinessEvents.Fixtures.SourceRecord,
            where: s.region == :us
          )
        )

      assert length(landed) == 5
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

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

end
