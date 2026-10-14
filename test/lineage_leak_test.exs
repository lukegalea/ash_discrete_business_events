# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LineageLeakTest do
  @moduledoc """
  The leak rule as an acceptance test (design §3.2) — red first.

  A lineage event carries structural names only: job, dataset, region,
  mapping-version. To make sure the assertion actually bites, it runs first
  against deliberately-leaking maps and must raise; only then is it trusted
  with fully-populated runs built with an actor, a tenant, a customer name
  and a filter value injected into every channel the package's API accepts —
  the batch payloads, the RunContext args, the emission opts, the
  correlation scope.

  Stream ranges are the case to watch: they appear only as facet-level
  COUNTS — a number, never a boundary value — and this suite is what holds
  that line as facets grow.
  """

  use ExUnit.Case, async: true

  import AshDiscreteBusinessEvents.TestSupport.LeakCheck, only: [assert_clean!: 2]

  alias AshDiscreteBusinessEvents.Fixtures.Correlation
  alias AshDiscreteBusinessEvents.Lineage
  alias AshDiscreteBusinessEvents.RunContext
  alias AshOpenLineage.Transport.InMemory

  # Every channel's injection: who ran it, for whom, and filtered to what.
  @actor "actor-777"
  @actor_email "leaky.actor@example.com"
  @tenant "tenant-acme-corp-42"
  @customer "Acme Corp & Sons"
  @filter_value "StageName = 'Closed Won'"

  setup do
    start_supervised!(InMemory)
    InMemory.clear()
    :ok
  end

  # ── the blade must cut ────────────────────────────────────────────────

  test "the leak check fails on a deliberately leaking map" do
    leaking_facet = %{
      "run" => %{
        "facets" => %{"bizevStats" => %{"lastBoundary" => @filter_value}}
      }
    }

    assert_raise ExUnit.AssertionError, ~r/leaks forbidden values/, fn ->
      assert_clean!(leaking_facet, forbidden())
    end

    # …on values buried at depth, keys included…
    assert_raise ExUnit.AssertionError, fn ->
      assert_clean!(%{"job" => %{"namespace" => @tenant}}, [@tenant])
    end

    # …and on a boundary value pretending to be a count.
    assert_raise ExUnit.AssertionError, fn ->
      assert_clean!(
        %{
          "outputs" => [
            %{"facets" => %{"bizevStats" => %{"lastSystemModstamp" => "2026-10-01T#{@customer}"}}}
          ]
        },
        forbidden()
      )
    end
  end

  # ── fully-populated runs, injected everywhere the API accepts ─────────

  test "a sync batch carries no actor, tenant, customer or filter value" do
    start_supervised!(Correlation)
    Correlation.script("corr-9f31c2ae", 0)
    Correlation.script_parent(nil)

    job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)
    run_id = Lineage.run_id(:operational)

    # The batch's rows carry the customer; a filter value and the actor sit
    # in whatever the caller had in scope, and the args travel JSON-shaped.
    rows = [%{"Name" => @customer, "StageName" => "Closed Won"}]

    args =
      RunContext.put_parent(%{}, "run-sync-1")
      |> Map.put("filter", @filter_value)
      |> Jason.encode!()
      |> Jason.decode!()

    result =
      RunContext.enter_from_args(args, fn ->
        Lineage.run(job, run_id, fn ->
          Enum.each(rows, fn _row -> :landed end)
        end)
      end)

    assert result == :ok

    [start, complete] = InMemory.events()
    assert_clean!(start, forbidden())
    assert_clean!(complete, forbidden())

    # the wire form, too
    assert_clean!(Jason.encode!(complete) |> Jason.decode!(), forbidden())
  end

  test "a FAIL event carries the structural failure, not the payload" do
    job = Lineage.job(:webhook, source: :stripe, stream: :charges)

    assert_raise RuntimeError, fn ->
      Lineage.run(job, "run-webhook-1", fn ->
        raise "webhook rejected for #{@customer}"
      end)
    end

    [start, fail] = InMemory.events()

    # The failure MESSAGE is operational truth (a broken pipeline must be
    # visible) — this assertion pins the STRUCTURAL surfaces, and the
    # customer name in a message is the operator's job to redact. What the
    # rule forbids is the event's structural content: job, datasets, facets.
    assert fail["run"]["facets"]["error"]["errorMessage"] =~ "webhook rejected"

    fail
    |> Map.delete("run")
    |> Map.put("run", %{"facets" => %{}})
    |> then(&assert_clean!(&1, forbidden()))

    assert_clean!(start, forbidden())
  end

  test "a derivation run with rule-version inputs carries versions, not values" do
    run_id =
      Lineage.run_id(%{
        purpose: :replay,
        ledger_range: %{"region" => "us", "after_sequence" => 100, "through_sequence" => 200},
        mapping_versions: ["bizev.rules.opportunity_stage_changed.v7fefb25c"]
      })

    job =
      Lineage.job(:replay,
        projection: :pipeline_history,
        region: :us,
        mapping_versions: [{:opportunity_stage_changed, "7fefb25c"}],
        output: "bizev.projection.pipeline_history"
      )

    Lineage.emit_start(job, run_id, correlation_id: "corr-4d11a77e", correlation_depth: 0)

    Lineage.emit_complete(job, run_id,
      correlation_id: "corr-4d11a77e",
      counts: %{"bizev.projection.pipeline_history" => 4200}
    )

    for event <- InMemory.events() do
      assert event["run"]["runId"] == run_id
      assert_clean!(event, forbidden())
      assert_clean!(Jason.encode!(event) |> Jason.decode!(), forbidden())
    end

    # and the counts facet is a number — a range's boundary never rides
    [_, complete] = InMemory.events()
    stats = hd(complete["outputs"])["facets"]["bizevStats"]
    assert stats["rowCount"] == 4200
    refute Map.has_key?(stats, "lastSequence")
    refute Map.has_key?(stats, "through")
  end

  test "a nested run's parent facet carries an opaque id only" do
    start_supervised!(Correlation)
    Correlation.script("corr-77e0b1d4", 1)
    Correlation.script_parent("enclosing-corr-91aa")

    job = Lineage.job(:sync, source: :salesforce, stream: :opportunity)

    # The parent channel is IDENTITY by design: an explicit :parent_run_id
    # rides verbatim (it is the host's correlation seam — an opaque id),
    # which is exactly why the sanctioned providers must be fed
    # correlation ids and never actor or tenant values. This test pins the
    # channel's contract: the id travels, the STRUCTURAL names stay clean.
    RunContext.establish(@tenant, fn ->
      Lineage.emit_complete(job, "run-nested-explicit",
        parent_run_id: RunContext.current_parent()
      )
    end)

    [event] = InMemory.events()
    assert event["run"]["facets"]["parent"]["run"]["runId"] == @tenant

    # The job and dataset names — the structural vocabulary — are untouched
    # by whatever the scope held:
    assert event["job"]["name"] == "bizev.sync.salesforce.opportunity"

    assert Enum.all?(event["inputs"] ++ event["outputs"], fn ds ->
             ds["name"] == "bizev.raw.salesforce.opportunity"
           end)
  end

  defp forbidden, do: [@actor, @actor_email, @tenant, @customer, @filter_value]
end
