# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.TriggersTest do
  @moduledoc """
  The BPMN trigger bridge (§5.2): nudge-on-append (the event kind +
  correlation key reach the host's EventSource), sweep-for-completeness
  (a missed nudge recovered, at-least-once), simulated rows never
  nudging, and the mapping's process correlation key landing on the
  ledger row's `process_ref` slot.
  """

  use ExUnit.Case, async: false

  alias AshDiscreteBusinessEvents.Fixtures.{Ledger, LedgerEvents, TriggerHandler}
  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Test.Repo
  alias AshDiscreteBusinessEvents.Triggers

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # The sweep's dispatch cursor is engine-checkpoint state — this file
    # owns it per test.
    Repo.delete_all("bizev_projection_checkpoints")

    start_supervised!(TriggerHandler)
    TriggerHandler.script(:ok)

    Application.put_env(:ash_discrete_business_events, :trigger_handler, TriggerHandler)
    on_exit(fn -> Application.delete_env(:ash_discrete_business_events, :trigger_handler) end)

    :ok
  end

  defp without_handler(fun) do
    Application.delete_env(:ash_discrete_business_events, :trigger_handler)
    fun.()
  after
    Application.put_env(:ash_discrete_business_events, :trigger_handler, TriggerHandler)
  end

  # ── nudge on append ───────────────────────────────────────────────────

  describe "nudge on append" do
    test "the handler receives the event — kind and correlation key aboard" do
      event = LedgerEvents.record!(subject_external_id: "trig-nudge-1")

      nudged = TriggerHandler.nudged()
      assert length(nudged) == 1

      nudge = hd(nudged)
      assert nudge.id == event.id
      assert nudge.action == :"opportunity.stage_changed"
      assert nudge.subject_external_id == "trig-nudge-1"
      assert nudge.process_ref == nil
      assert nudge.sequence == event.sequence
    end

    test "simulated rows never nudge — synthetic events stay out of the real machinery" do
      LedgerEvents.simulate!(
        subject_external_id: "trig-nudge-sim",
        simulation_run: "bpmn-whatif",
        occurred_at: ~U[2026-10-01 10:00:00Z]
      )

      assert TriggerHandler.nudged() == []
    end

    test "no handler configured: the record stands, nothing nudges" do
      without_handler(fn ->
        event = LedgerEvents.record!(subject_external_id: "trig-nudge-2")
        assert event.id
        assert TriggerHandler.nudged() == []
      end)
    end

    test "a failed nudge never fails the record — the sweep recovers it" do
      TriggerHandler.script({:error, "bpmn down"})

      event = LedgerEvents.record!(subject_external_id: "trig-nudge-3")
      assert event.id

      # The nudge was ATTEMPTED (and failed loudly to the handler's
      # outcome) — but the record stands.
      assert length(TriggerHandler.nudged()) == 1

      # The handler recovers; the sweep re-dispatches the missed nudge.
      TriggerHandler.script(:ok)
      assert {:ok, %{dispatched: 1}} = Triggers.sweep(Ledger, :us)

      recovered = List.last(TriggerHandler.nudged())
      assert recovered.id == event.id
    end
  end

  # ── sweep for completeness ────────────────────────────────────────────

  describe "sweep for completeness" do
    test "a missed nudge (recorded before the handler existed) is recovered, in sequence order" do
      # Missed nudges: recorded while the bridge was dormant.
      without_handler(fn ->
        a = LedgerEvents.record!(subject_external_id: "trig-sweep-a")
        b = LedgerEvents.record!(subject_external_id: "trig-sweep-b")
        %{a: a, b: b}
      end)
      |> then(fn %{a: a, b: b} ->
        assert TriggerHandler.nudged() == []

        assert {:ok, %{dispatched: 2}} = Triggers.sweep(Ledger, :us)

        nudged = TriggerHandler.nudged()
        assert Enum.map(nudged, & &1.id) == [a.id, b.id]
        assert Enum.map(nudged, & &1.sequence) == Enum.sort(Enum.map(nudged, & &1.sequence))

        # Complete: the sweep's cursor stands at the last dispatch.
        assert {:ok, %{dispatched: 0}} = Triggers.sweep(Ledger, :us)
      end)
    end

    test "a sweep stops at a failure — the cursor stands, the retry lands" do
      without_handler(fn ->
        LedgerEvents.record!(subject_external_id: "trig-sweep-c")
      end)

      LedgerEvents.record!(subject_external_id: "trig-sweep-d")

      # The handler fails on the FIRST event: the sweep dispatches
      # nothing (the attempt failed), the cursor stands at the start.
      TriggerHandler.script({:error, "still down"})

      assert {:ok, %{dispatched: 0}} = Triggers.sweep(Ledger, :us)

      # Recovered: the next sweep dispatches everything the cursor stood
      # behind, in order.
      TriggerHandler.script(:ok)
      assert {:ok, %{dispatched: 2}} = Triggers.sweep(Ledger, :us)

      # The handler's capture log includes the FAILED attempts (the
      # sweep's 0-dispatched is the dispatch truth); the recovery's two
      # dispatches land last, in sequence order.
      nudged = TriggerHandler.nudged()

      assert Enum.map(Enum.take(nudged, -2), & &1.subject_external_id) == [
               "trig-sweep-c",
               "trig-sweep-d"
             ]
    end

    test "the sweep never dispatches simulated events — the twin is not swept" do
      without_handler(fn ->
        LedgerEvents.simulate!(
          subject_external_id: "trig-sweep-sim",
          simulation_run: "bpmn-whatif",
          occurred_at: ~U[2026-10-01 10:00:00Z]
        )
      end)

      assert {:ok, %{dispatched: 0}} = Triggers.sweep(Ledger, :us)
      assert TriggerHandler.nudged() == []
    end
  end

  # ── process context as data (§5.2) ────────────────────────────────────

  describe "the process correlation key" do
    test "a mapping's process_key lands the payload value on the canonical output and the ledger row" do
      defmodule Host.ProcessKeyed do
        use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

        business_events do
          source :s do
            region(:us)
            stream(:t)
          end

          mapping :keyed do
            source {:s, :t}
            process_key("OpportunityId")

            map(:stage, from: "Stage", type: :string)
            map(:occurred_at, from: "At", type: :utc_datetime_usec)
          end
        end
      end

      mapping = Info.mapping(Host.ProcessKeyed, :keyed)
      artifact = AshDiscreteBusinessEvents.Mappings.Compiler.artifact(mapping)
      assert artifact["process_key"] == "OpportunityId"

      payload = %{
        "Stage" => "Closed Won",
        "At" => "2026-06-01T05:32:48Z",
        "OpportunityId" => "opp-77"
      }

      assert {:ok, canonical} =
               AshDiscreteBusinessEvents.Mappings.Compiler.run(artifact, payload)

      assert canonical.process_ref == "opp-77"

      # …and the ledger row carries it in the §5.2 slot.
      event =
        Ledger.record!(%{
          event_kind: canonical.event_kind,
          region: :us,
          residency_tag: "us",
          subject_type: "crm.opportunity",
          subject_external_id: canonical.process_ref,
          occurred_at: canonical.occurred_at,
          provenance: %{"mapping_name" => "keyed", "mapping_version_hash" => "00000001"},
          process_ref: canonical.process_ref,
          data: canonical.data
        })

      assert event.process_ref == "opp-77"
    end

    test "no process_key: the canonical output carries no process_ref, the row's slot stays nil" do
      mapping =
        Info.mapping(AshDiscreteBusinessEvents.Fixtures.CorpusHost, :opportunity_stage_changed)

      artifact = AshDiscreteBusinessEvents.Mappings.Compiler.artifact(mapping)
      refute artifact["process_key"]

      payload = %{"Stage" => "Won", "SystemModstamp" => "2026-06-01T05:32:48Z"}

      assert {:ok, canonical} =
               AshDiscreteBusinessEvents.Mappings.Compiler.run(artifact, payload)

      refute Map.has_key?(canonical, :process_ref)
    end
  end
end
