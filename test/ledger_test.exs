# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LedgerTest do
  @moduledoc """
  The §1.4 row contract against the REAL resource — the BIZEV-2
  fixture's 17 columns, the machinery fields they ride, append-only,
  delivery idempotency, corrections-as-events, and the region
  discipline on reads.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Ledger

  alias AshDiscreteBusinessEvents.Fixtures.LedgerEvents

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{subject: LedgerEvents.subject_external_id()}
  end

  describe "the §1.4 row contract" do
    test "every frozen column lands, and the machinery fields ride correctly", %{
      subject: subject
    } do
      event = LedgerEvents.record!(subject_external_id: subject)

      # what
      assert event.action == :"opportunity.stage_changed"
      assert event.data["to_stage"] == "Proposal"

      # what-subject — descriptors, never FKs
      assert event.subject_type == "crm.opportunity"
      assert event.subject_external_id == subject
      assert event.subject_stream == :opportunity
      assert event.record_id == subject

      # who — verbatim external actor
      assert event.actor_type == "crm.user"
      assert event.actor_external_id == "0055f000001AbCdAAF"
      assert event.actor_display == "Dana Ops"

      # when — three clocks, three questions
      assert event.occurred_at == ~U[2026-10-01 14:03:00.000000Z]
      assert %DateTime{} = event.observed_at
      assert is_integer(event.sequence) and event.sequence > 0

      # why — context from the source, provenance as data
      assert event.context["reason_code"] == "stage_progression"
      assert event.provenance["mapping_name"] == "opportunity_stage_changed"
      assert event.provenance["mapping_version_hash"] == "b3f2c9a1"
      assert event.provenance["source_record_id"]

      # corrections — nullable on ordinary events
      assert event.supersedes_event_id == nil

      # delivery — nil when there is no delivery context
      assert event.delivery_key == nil

      # region
      assert event.region == :us
      assert event.residency_tag == "us"

      # the AshEvents substrate's view (§5.1)
      assert event.action_type == :create
      assert event.resource == :"bizev.event"
      assert event.version == 1
    end
  end

  describe "append-only" do
    test "no update or destroy actions exist" do
      assert Ash.Resource.Info.action(Ledger, :update) == nil
      assert Ash.Resource.Info.action(Ledger, :destroy) == nil
      # The stock create AshEvents adds is removed: record is the only path.
      assert Ash.Resource.Info.action(Ledger, :create) == nil
      refute Ash.Resource.Info.action(Ledger, :record) == nil
    end

    test "the database refuses UPDATE and DELETE (the immutability trigger)", %{
      subject: subject
    } do
      event = LedgerEvents.record!(subject_external_id: subject)
      repo = AshDiscreteBusinessEvents.Test.Repo
      raw_id = Ecto.UUID.dump!(event.id)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        repo.query!(
          "UPDATE ledger_events SET data = data || '{\"tampered\": true}' WHERE id = $1",
          [raw_id]
        )
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        repo.query!("DELETE FROM ledger_events WHERE id = $1", [raw_id])
      end
    end
  end

  describe "caller context reaches the append" do
    test "the caller's actor is the append's actor", %{subject: subject} do
      assert_raise Ash.Error.Forbidden, fn ->
        Ledger.record!(LedgerEvents.event(subject_external_id: subject),
          actor: %{blocked?: true}
        )
      end
    end

    test "authorize?: false on record is authorize?: false on the append", %{subject: subject} do
      event =
        Ledger.record!(LedgerEvents.event(subject_external_id: subject),
          actor: %{blocked?: true},
          authorize?: false
        )

      assert event.subject_external_id == subject
    end
  end

  describe "optional arguments" do
    test "a record naming only the required arguments lands", %{subject: subject} do
      event =
        Ledger.record!(%{
          event_kind: :"opportunity.created",
          region: :us,
          residency_tag: "us",
          subject_type: "crm.opportunity",
          subject_external_id: subject,
          occurred_at: ~U[2026-10-01 14:03:00.000000Z],
          provenance: LedgerEvents.provenance()
        })

      assert event.subject_external_id == subject
      assert event.actor_display == nil
      assert event.delivery_key == nil
    end
  end

  describe "delivery idempotency (per region)" do
    test "a repeated delivery_key collapses to the existing row", %{subject: subject} do
      first =
        LedgerEvents.record!(
          subject_external_id: subject,
          delivery_key: "hook:retry:#{subject}"
        )

      second =
        LedgerEvents.record!(
          subject_external_id: subject,
          delivery_key: "hook:retry:#{subject}",
          occurred_at: ~U[2026-10-02 08:00:00.000000Z]
        )

      assert second.id == first.id

      assert Ledger.by_region!(:us)
             |> Enum.count(&(&1.subject_external_id == subject)) == 1
    end

    test "the same delivery_key in ANOTHER region is its own row (no silent region merge)", %{
      subject: subject
    } do
      us =
        LedgerEvents.record!(
          subject_external_id: subject,
          delivery_key: "hook:cross:#{subject}"
        )

      ca =
        LedgerEvents.record!(
          subject_external_id: subject,
          region: :ca,
          residency_tag: "ca",
          delivery_key: "hook:cross:#{subject}"
        )

      assert us.id != ca.id
      assert ca.region == :ca
    end
  end

  describe "corrections are events" do
    test "supersedes_event_id rides the correction; the original is untouched", %{
      subject: subject
    } do
      original = LedgerEvents.record!(subject_external_id: subject)

      correction =
        LedgerEvents.record!(
          subject_external_id: subject,
          occurred_at: original.occurred_at,
          supersedes_event_id: original.id,
          data: %{"to_stage" => "Negotiation", "amount" => 97_500}
        )

      assert correction.supersedes_event_id == original.id
      assert correction.sequence > original.sequence

      # The original still reads exactly as recorded:
      reread = Ledger.by_id!(original.id, :us)
      assert reread.data["to_stage"] == "Proposal"
    end
  end

  describe "region discipline on reads" do
    test "the feed resumes strictly after the high-water mark, in sequence order", %{
      subject: subject
    } do
      e1 = LedgerEvents.record!(subject_external_id: subject)

      e2 =
        LedgerEvents.record!(
          subject_external_id: subject,
          occurred_at: ~U[2026-10-02 08:00:00.000000Z]
        )

      e3 =
        LedgerEvents.record!(
          subject_external_id: subject,
          occurred_at: ~U[2026-10-03 09:00:00.000000Z]
        )

      feed = Ledger.feed!(:us)
      assert Enum.map(feed, & &1.sequence) == Enum.sort(Enum.map(feed, & &1.sequence))
      assert e1.sequence in Enum.map(feed, & &1.sequence)

      resumed = Ledger.feed!(:us, %{after_sequence: e2.sequence})
      refute e1.sequence in Enum.map(resumed, & &1.sequence)
      refute e2.sequence in Enum.map(resumed, & &1.sequence)
      assert e3.sequence in Enum.map(resumed, & &1.sequence)
    end

    test "by_subject scopes to one region's subject", %{subject: subject} do
      LedgerEvents.record!(subject_external_id: subject)
      LedgerEvents.record!(subject_external_id: subject, region: :ca, residency_tag: "ca")

      us_events = Ledger.by_subject!(:us, subject)
      assert length(us_events) == 1
      assert hd(us_events).region == :us
    end

    test "cross_region_read is gated (needs 2+ regions), discloses per region, and scans", %{
      subject: subject
    } do
      LedgerEvents.record!(subject_external_id: subject)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          Ledger.cross_region_read!(%{regions: [:us], purpose: "one-region shortcut"})
        end

      assert Exception.message(hd(error.errors)) =~ "at least two regions"

      rows =
        Ledger.cross_region_read!(%{regions: [:us, :ca], purpose: "quarterly reconciliation"})

      assert Enum.any?(rows, &(&1.region == :us))
      assert Enum.any?(rows, &(&1.region == :ca))

      # One disclosure per queried region, each IN its own region's chain:
      for region <- [:us, :ca] do
        disclosures =
          Ledger.by_region!(region)
          |> Enum.filter(&(&1.action == :"region.disclosure"))

        assert length(disclosures) == 1
        disclosure = hd(disclosures)
        assert disclosure.data["purpose"] == "quarterly reconciliation"
        assert disclosure.data["regions"] == ["us", "ca"]
      end
    end
  end
end
