# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LineageTest do
  @moduledoc """
  The lineage contract (design §3): the structural naming vocabulary, the
  job builders, the run-identity split (operational = correlation-derived,
  derivation = content-derived), the job-template emission shape at BATCH
  granularity, and the RunContext fan-out threading.
  """

  use ExUnit.Case, async: true

  import AshDiscreteBusinessEvents.TestSupport.LeakCheck, only: [assert_clean!: 2]

  alias AshDiscreteBusinessEvents.Fixtures.Correlation
  alias AshDiscreteBusinessEvents.Lineage
  alias AshDiscreteBusinessEvents.RunContext
  alias AshOpenLineage.Transport.InMemory

  @base_facet_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/BaseFacet"

  setup do
    start_supervised!(InMemory)
    InMemory.clear()
    :ok
  end

  # ── the naming vocabulary (§3.2) ──────────────────────────────────────

  describe "the structural naming vocabulary" do
    test "every row of the design's table, exact" do
      assert Lineage.sync_job_name(:salesforce, :opportunity) == "bizev.sync.salesforce.opportunity"
      assert Lineage.webhook_job_name(:stripe) == "bizev.webhook.stripe"
      assert Lineage.replay_job_name(:pipeline_history) == "bizev.replay.pipeline_history"
      assert Lineage.raw_dataset(:salesforce, :opportunity) == "bizev.raw.salesforce.opportunity"
      assert Lineage.ledger_dataset(:us) == "bizev.ledger.us"

      assert Lineage.rules_dataset(:opportunity_stage_changed, "7fefb25c") ==
               "bizev.rules.opportunity_stage_changed.v7fefb25c"
    end

    test "every name is structural: no values, only declared names" do
      assert_clean!(Lineage.sync_job_name(:salesforce, :opportunity), forbidden())
      assert_clean!(Lineage.rules_dataset(:opportunity_stage_changed, "7fefb25c"), forbidden())
    end
  end

  describe "job builders" do
    test "a sync job outputs the stream's raw dataset" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

      assert job.namespace == "bizev"
      assert job.name == "bizev.sync.salesforce.opportunity"
      assert job.inputs == []
      assert job.outputs == ["bizev.raw.salesforce.opportunity"]
    end

    test "a webhook job is per source; its raw output needs the stream pinned" do
      bare = Lineage.job(:webhook, source: :stripe)
      assert bare.name == "bizev.webhook.stripe"
      assert bare.outputs == []

      pinned = Lineage.job(:webhook, source: :stripe, stream: :charges)
      assert pinned.outputs == ["bizev.raw.stripe.charges"]
    end

    test "a replay job is a derivation: it reads the ledger and the rule versions" do
      job =
        Lineage.job(:replay,
          projection: :pipeline_history,
          region: :us,
          mapping_versions: [{:opportunity_stage_changed, "7fefb25c"}],
          output: "bizev.projection.pipeline_history"
        )

      assert job.name == "bizev.replay.pipeline_history"
      assert "bizev.ledger.us" in job.inputs
      assert "bizev.rules.opportunity_stage_changed.v7fefb25c" in job.inputs
      assert job.outputs == ["bizev.projection.pipeline_history"]
    end

    test "the vocabulary is closed: extra opts are ignored, not smuggled" do
      # A descriptor carries structural names only — whatever else the
      # caller had in scope cannot ride along (the leak rule, structurally).
      job =
        Lineage.job(:sync,
          source: :salesforce,
          stream: :opportunity,
          filter: "StageName = 'Closed Won'",
          tenant: "tenant-acme"
        )

      assert job == %{
               namespace: "bizev",
               name: "bizev.sync.salesforce.opportunity",
               inputs: [],
               outputs: ["bizev.raw.salesforce.opportunity"]
             }
    end
  end

  # ── run identity per job class (§3.3) ─────────────────────────────────

  describe "run identity — the split" do
    test "operational runs are correlation-derived: the provider's id" do
      start_supervised!(Correlation)
      Correlation.script("corr-from-audit-log-42", 0)

      assert Lineage.run_id(:operational) == "corr-from-audit-log-42"
    end

    test "derivation runs are content-derived: same inputs, same run id" do
      spec = %{
        purpose: :replay,
        ledger_range: %{region: :us, after_sequence: 100, through_sequence: 200},
        mapping_versions: ["bizev.rules.opportunity_stage_changed.v7fefb25c"]
      }

      id_a = Lineage.run_id(spec)
      id_b = Lineage.run_id(spec)

      assert id_a == id_b
      # A UUID — an OpenLineage consumer reads a runId.
      assert id_a =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "derivation runs hash the CONTENT: different inputs, different run ids" do
      base = %{
        purpose: :replay,
        ledger_range: %{region: :us, after_sequence: 100, through_sequence: 200},
        mapping_versions: ["bizev.rules.opportunity_stage_changed.v7fefb25c"]
      }

      other_range = %{base | ledger_range: %{region: :us, after_sequence: 100, through_sequence: 300}}
      other_purpose = %{base | purpose: :remap_backfill}
      other_versions = %{base | mapping_versions: ["bizev.rules.opportunity_stage_changed.vaaaaaaa1"]}

      assert Lineage.run_id(base) != Lineage.run_id(other_range)
      assert Lineage.run_id(base) != Lineage.run_id(other_purpose)
      assert Lineage.run_id(base) != Lineage.run_id(other_versions)
    end

    test "the mapping-version set is order-insensitive — a permuted list is the same content" do
      spec = %{
        purpose: :replay,
        ledger_range: %{region: :us},
        mapping_versions: ["bizev.rules.a.v11111111", "bizev.rules.b.v22222222"]
      }

      permuted = %{spec | mapping_versions: Enum.reverse(spec.mapping_versions)}

      assert Lineage.run_id(spec) == Lineage.run_id(permuted)
    end

    test "a derivation spec with a non-serializable range is refused" do
      assert_raise ArgumentError, ~r/JSON-serializable/, fn ->
        Lineage.run_id(%{purpose: :replay, ledger_range: {:fn, fn -> :ok end}})
      end
    end
  end

  # ── the job-template emission shape (§3.1) ────────────────────────────

  describe "run/3 — the batch template" do
    test "START before the run, COMPLETE after, sharing the run id" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)
      run_id = Lineage.run_id(:operational)

      result = Lineage.run(job, run_id, fn -> 3 end)

      assert result == 3

      assert [%{"eventType" => "START"}, %{"eventType" => "COMPLETE"}] = InMemory.events()

      for event <- InMemory.events() do
        assert event["run"]["runId"] == run_id
        assert event["job"]["name"] == "bizev.sync.salesforce.opportunity"
        assert event["outputs"] == [%{"namespace" => "bizev", "name" => "bizev.raw.salesforce.opportunity"}]
      end
    end

    test "BATCH granularity: N rows are one job — two events, never per-row COMPLETEs" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)
      run_id = Lineage.run_id(:operational)

      rows = ["row-1", "row-2", "row-3"]

      Lineage.run(job, run_id, fn -> Enum.each(rows, fn _row -> :landed end) end)

      # Three rows landed; the graph sees ONE job that ran once.
      assert length(InMemory.events()) == 2
    end

    test "a raise emits FAIL loudly — with the reason — and re-raises" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)
      run_id = Lineage.run_id(:operational)

      assert_raise RuntimeError, ~r/daily API budget exhausted/, fn ->
        Lineage.run(job, run_id, fn -> raise "daily API budget exhausted" end)
      end

      assert [%{"eventType" => "START"}, %{"eventType" => "FAIL"}] = InMemory.events()
      assert [%{}, fail] = InMemory.events()
      assert fail["run"]["runId"] == run_id
      assert fail["run"]["facets"]["error"]["errorMessage"] =~ "daily API budget exhausted"
    end

    test "a throw emits FAIL and re-throws; an exit emits FAIL and re-exits" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

      assert catch_throw(Lineage.run(job, "run-1", fn -> throw :halted end)) == :halted
      assert catch_exit(Lineage.run(job, "run-2", fn -> exit :shutdown end)) == :shutdown

      fails = Enum.filter(InMemory.events(), &(&1["eventType"] == "FAIL"))
      assert length(fails) == 2
      assert Enum.all?(fails, &(&1["run"]["runId"] in ["run-1", "run-2"]))
    end

    test "counts land as facet-level stats on the outputs — numbers, never boundary values" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

      Lineage.emit_complete(job, "run-counts",
        counts: %{"bizev.raw.salesforce.opportunity" => 42}
      )

      [event] = InMemory.events()

      assert event["outputs"] == [
               %{
                 "namespace" => "bizev",
                 "name" => "bizev.raw.salesforce.opportunity",
                 "facets" => %{
                   "bizevStats" => %{
                     "_producer" => Lineage.producer(),
                     "_schemaURL" => @base_facet_url,
                     "rowCount" => 42
                   }
                 }
               }
             ]
    end

    test "the emission vocabulary is closed: arbitrary opts cannot ride through" do
      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

      Lineage.emit_complete(job, "run-clean",
        filter: "StageName = 'Closed Won'",
        tenant: "tenant-acme"
      )

      [event] = InMemory.events()
      assert_clean!(event, forbidden())
    end
  end

  # ── fan-out parent propagation (§3.4) ─────────────────────────────────

  describe "RunContext — parent threading" do
    test "parent ids travel in Oban args as STRING keys" do
      args = RunContext.put_parent(%{"source" => :salesforce}, "run-parent-1")

      assert Map.get(args, "bizev_parent_run_id") == "run-parent-1"
      assert RunContext.parent_from_args(args) == "run-parent-1"
    end

    test "an atom-keyed look-alike is invisible — the iron law, pinned" do
      # Oban's JSON round-trip would erase this key; pretending to read it
      # is how the miss goes silent.
      assert RunContext.parent_from_args(%{bizev_parent_run_id: "run-parent-1"}) == nil
    end

    test "the parent id survives a real JSON round-trip" do
      args =
        RunContext.put_parent(%{"cursor" => "2026-10-01"}, "run-parent-2")
        |> Jason.encode!()
        |> Jason.decode!()

      assert RunContext.parent_from_args(args) == "run-parent-2"
    end

    test "enter_from_args re-establishes the scope at worker entry" do
      args = RunContext.put_parent(%{}, "run-parent-3")

      result = RunContext.enter_from_args(args, fn -> RunContext.current_parent() end)

      assert result == "run-parent-3"
      # and the scope does not leak past the block
      assert RunContext.current_parent() == nil
    end

    test "a nil parent is established as nothing — not fabricated" do
      result = RunContext.enter_from_args(%{}, fn -> RunContext.current_parent() end)
      assert result == nil
    end

    test "the host scope establisher wraps the block, arity-2 shape" do
      Application.put_env(:ash_discrete_business_events, :scope_establisher, {
        AshDiscreteBusinessEvents.RunContextTestHost,
        :with_scope
      })

      on_exit(fn -> Application.delete_env(:ash_discrete_business_events, :scope_establisher) end)

      result =
        RunContext.establish("run-parent-4", fn ->
          RunContext.current_parent() |> then(&{:inner, &1})
        end)

      assert result == {:inner, "run-parent-4"}
      assert Process.get(:host_scope_seen) == "run-parent-4"
      assert Process.get(:host_scope_depth) == 1
    end

    test "fan_out passes the parent explicitly into every spawned task" do
      items = [1, 2, 3, 4]

      results =
        RunContext.establish("run-parent-5", fn ->
          RunContext.fan_out(items, fn item ->
            {item, RunContext.current_parent()}
          end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort()
        end)

      assert results == Enum.map(items, &{&1, "run-parent-5"})
      # and the parent scope does not leak into the calling process's tasks
      assert RunContext.current_parent() == nil
    end

    test "fan_out outside a run passes no parent — and still fans out" do
      results =
        RunContext.fan_out([:a, :b], fn item -> {item, RunContext.current_parent()} end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort()

      assert results == [{:a, nil}, {:b, nil}]
    end
  end

  describe "parent facet — depth>0 from the sanctioned providers" do
    test "depth 0 emits no parent facet" do
      start_supervised!(Correlation)
      Correlation.script("corr-1", 0)
      Correlation.script_parent("enclosing-run")

      Lineage.emit_complete(Lineage.job(:sync, source: :salesforce, stream: :opportunity), "run-d0")

      [event] = InMemory.events()
      refute Map.has_key?(event["run"]["facets"], "parent")
    end

    test "depth>0 with a resolvable parent adds the parent run facet" do
      start_supervised!(Correlation)
      Correlation.script("corr-2", 1)
      Correlation.script_parent("enclosing-run-7")

      Lineage.emit_complete(Lineage.job(:sync, source: :salesforce, stream: :opportunity), "run-d1")

      [event] = InMemory.events()
      assert event["run"]["facets"]["parent"]["run"]["runId"] == "enclosing-run-7"
    end

    test "depth>0 without a resolvable parent omits the facet — never fabricated" do
      start_supervised!(Correlation)
      Correlation.script("corr-3", 2)
      Correlation.script_parent(nil)

      Lineage.emit_complete(Lineage.job(:sync, source: :salesforce, stream: :opportunity), "run-d2")

      [event] = InMemory.events()
      refute Map.has_key?(event["run"]["facets"], "parent")
    end

    test "the RunContext scope wins as the parent id inside a run" do
      start_supervised!(Correlation)
      Correlation.script("corr-4", 1)
      Correlation.script_parent("stale-enclosing-run")

      job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

      Lineage.run(job, "run-outer", fn ->
        # No explicit :parent_run_id — parent_opts/0 resolves it from the
        # RunContext scope the worker re-established.
        RunContext.establish("fresh-parent", fn ->
          Lineage.emit_complete(job, "run-nested")
        end)
      end)

      [complete] =
        Enum.filter(InMemory.events(), &(&1["eventType"] == "COMPLETE" and &1["run"]["runId"] == "run-nested"))

      assert complete["run"]["facets"]["parent"]["run"]["runId"] == "fresh-parent"
    end
  end

  # ── no per-row notifier, anywhere (§3.1) ──────────────────────────────

  describe "emission ownership — batch, not row" do
    test "no BIZEV resource carries the AshOpenLineage notifier" do
      for resource <- [
            AshDiscreteBusinessEvents.Fixtures.SourceRecord,
            AshDiscreteBusinessEvents.Fixtures.Ledger,
            AshDiscreteBusinessEvents.Fixtures.MappingVersion
          ] do
        refute AshOpenLineage.Extension in Ash.Resource.Info.extensions(resource),
               "#{inspect(resource)} must not register the per-row lineage notifier"
      end
    end

    @tag :db
    test "landing N raw rows emits ZERO lineage events — rows are not jobs" do
      Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)

      for _ <- 1..3 do
        AshDiscreteBusinessEvents.Fixtures.Observations.land!()
      end

      # Three rows landed; the graph saw nothing — the batch's job template
      # is the only emitter, and it wasn't told about this landing.
      assert InMemory.events() == []
    end
  end

  defp forbidden,
    do: [
      "actor-777",
      "leaky.actor@example.com",
      "tenant-acme-corp-42",
      "Acme Corp & Sons",
      "StageName = 'Closed Won'"
    ]

end

  defmodule AshDiscreteBusinessEvents.RunContextTestHost do
  @moduledoc """
  The host-side scope establisher's test double — `Correlation.with_
  correlation/2`'s exact shape: `(correlation_id, fun)` running `fun` in the
  host's scope. Marks the process so the test can see it ran.
  """

  def with_scope(parent_id, fun) do
    Process.put(:host_scope_seen, parent_id)
    Process.put(:host_scope_depth, 1 + (Process.get(:host_scope_depth) || 0))
    fun.()
  end
end
