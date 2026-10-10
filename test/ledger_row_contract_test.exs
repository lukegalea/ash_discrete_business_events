# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.LedgerRowContractTest do
  @moduledoc """
  The ledger row contract, pinned as data (design §1.4's table).

  BIZEV-2 ships no ledger resource — that is BIZEV-4. What this slice
  owes the design is the *shape freeze*: the columns below, their
  meanings, and the invariants the design states about them, locked
  here as fixtures so BIZEV-4's resource either matches the contract or
  the contract test fails. The examples are the design's own: a
  Salesforce opportunity stage change, and the correction event that
  supersedes it.

  These are plain data-structure tests on purpose: the contract precedes
  the implementation, and no database is needed to state it.
  """

  use ExUnit.Case, async: true

  # ── The §1.4 contract, column by column ────────────────────────────────
  # Every ledger row carries exactly these; BIZEV-4 adds no columns
  # without amending this test (and citing the design section that
  # motivates the amendment).

  @columns %{
    event_kind:
      "what — the discrete business event (stored in AshEvents' `action`); " <>
        "projector-dispatchable as-is, e.g. \"opportunity.stage_changed\"",
    data: "what — the canonical mapped payload the projector folds",
    subject_type:
      "what-subject — descriptor, never an FK (ADR 0017 resolution is projection work)",
    subject_external_id:
      "what-subject — the external id; VendorPM Law 1: idempotency keys, never identities",
    subject_stream: "what-subject — which stream the subject was observed in",
    actor_type:
      "who — verbatim external actor type; resolution to internal Person is projection work",
    actor_external_id:
      "who — verbatim external actor id; keeps land pure (replay-deterministic) and PII-minimal",
    actor_display: "who — the display name the source supplied, carried verbatim",
    occurred_at: "when — source truth time (e.g. SystemModstamp); the event happened then",
    observed_at: "when — when WE learned of it; late arrival is ordinary, never hidden",
    sequence:
      "when — commit order within the region (advisory-xact-lock before insert); " <>
        "a high-watermark cursor on this can never silently skip a row",
    context: "why — structured, optional: reason codes / description fields the source supplies",
    provenance:
      "why — the system-side why: mapping_name, mapping_version_hash, source_record_id; " <>
        "reconstructable from the row alone",
    supersedes_event_id:
      "corrections — nullable; corrections are NEW events, the original is never rewritten (chain integrity)",
    delivery_key:
      "delivery — unique; webhook retries idempotent at the delivery level, below source idempotency",
    region: "region — first-class; drives admission, chains, sequences, cursors (§6)",
    residency_tag:
      "region — the residency declaration admission checked at land (refuse-until-tagged)"
  }

  @spec columns :: %{required(atom) => String.t()}
  defp columns, do: @columns

  # ── Fixture: the design's example event ────────────────────────────────
  # A Salesforce opportunity moved from Qualification to Proposal at
  # 14:03; the Bulk 2.0 sync observed it nine minutes later. Same
  # shape as the row BIZEV-4 writes. (BIZEV-4 amendment, cited: §5.1
  # stores event_kind in AshEvents' `action`, an ATOM column — the
  # projector DSL's `project "opportunity.stage_changed"` converts the
  # string form to the atom at compile time. The written form in the
  # design's table is the string; the stored form is the atom.)

  @example_event %{
    event_kind: :"opportunity.stage_changed",
    data: %{
      from_stage: "Qualification",
      to_stage: "Proposal",
      amount: Decimal.new("95000.00"),
      currency: "USD"
    },
    subject_type: "crm.opportunity",
    subject_external_id: "0065f000003Xy7ZAAS",
    subject_stream: :opportunity,
    actor_type: "crm.user",
    actor_external_id: "0055f000001AbCdAAF",
    actor_display: "Dana Ops",
    occurred_at: ~U[2026-10-01 14:03:00Z],
    observed_at: ~U[2026-10-01 14:09:41Z],
    sequence: 42_817,
    context: %{
      reason_code: "stage_progression",
      description: "Stage moved from Qualification to Proposal"
    },
    provenance: %{
      mapping_name: "opportunity_stage_changed",
      mapping_version_hash: "b3f2c9a1",
      source_record_id: "01984f7a-6d1e-7332-9c4f-2b1e0a9d5e01"
    },
    supersedes_event_id: nil,
    delivery_key: "bulk20:0Af5f00000ABcDEAG:opportunity:000123",
    region: :us,
    residency_tag: "us"
  }

  # ── Fixture: a correction is a new event ───────────────────────────────
  # §7: the mapping later sees a SourceRecord version whose extracted
  # facts differ from a previously-ledgered event for the same subject
  # truth-point — it derives a NEW row with supersedes_event_id set.

  @correction_event %{
    @example_event
    | data: %{
        from_stage: "Qualification",
        to_stage: "Negotiation",
        amount: Decimal.new("97500.00"),
        currency: "USD"
      },
      occurred_at: ~U[2026-10-01 14:03:00Z],
      observed_at: ~U[2026-10-02 08:15:12Z],
      sequence: 43_002,
      supersedes_event_id: "01984f7a-6d1e-7332-9c4f-2b1e0a9d5e77",
      delivery_key: "bulk20:0Af5f00000ABcDEAG:opportunity:000124",
      provenance: %{
        mapping_name: "opportunity_stage_changed",
        mapping_version_hash: "b3f2c9a1",
        source_record_id: "01984f7a-6d1e-7332-9c4f-2b1e0a9d5e90"
      }
  }

  describe "the §1.4 column set" do
    test "the frozen columns are exactly the design's table" do
      assert Map.keys(columns()) |> Enum.sort() == [
               :actor_display,
               :actor_external_id,
               :actor_type,
               :context,
               :data,
               :delivery_key,
               :event_kind,
               :observed_at,
               :occurred_at,
               :provenance,
               :region,
               :residency_tag,
               :sequence,
               :subject_external_id,
               :subject_stream,
               :subject_type,
               :supersedes_event_id
             ]
    end

    test "the example event carries every column, with every column documented" do
      for {column, doc} <- columns() do
        assert Map.has_key?(@example_event, column),
               "example event is missing contract column #{inspect(column)}"

        assert is_binary(doc) and doc != "",
               "contract column #{inspect(column)} lost its §1.4 doc"
      end
    end

    test "event_kind rides the row for projector dispatch" do
      # §5.1: event_kind rides AshEvents' `action` (an atom column), so
      # projectors written in the existing DSL drain business events
      # unchanged — `project "opportunity.stage_changed"` matches the
      # atom form. BIZEV-4 maps the row's event_kind onto AshEvents'
      # action field verbatim.
      assert is_atom(@example_event.event_kind)
      assert @example_event.event_kind |> Atom.to_string() =~ "."
    end

    test "subject and actor are descriptors, not identities" do
      # VendorPM Law 1 / ADR 0017: linking to internal entities is
      # projection/entity-resolution work, never done at land. The row
      # carries (type, external_id, stream/display) only — no FK, no
      # resolved internal id. Types are strings (they cross JSON
      # boundaries and projector args verbatim); the stream keeps the
      # DSL's atom vocabulary.
      descriptor_columns = [
        :subject_type,
        :subject_external_id,
        :subject_stream,
        :actor_type,
        :actor_external_id,
        :actor_display
      ]

      row_columns = @example_event |> Map.keys()

      assert Enum.all?(descriptor_columns, &(&1 in row_columns)),
             "the subject/actor descriptor columns drifted from the §1.4 table"

      # …and there is no resolved-identity column to be found:
      refute Enum.any?(
               row_columns,
               &(&1 in [:subject_id, :actor_id, :person_id, :account_id])
             )
    end

    test "the three clocks are three different questions (§1.4)" do
      # occurred_at = truth time; observed_at = knowledge time;
      # sequence = commit order. Here the observation lagged the truth by
      # nine minutes — late arrival is ordinary, and no column pretends
      # otherwise.
      assert DateTime.compare(@example_event.occurred_at, @example_event.observed_at) == :lt
      assert @example_event.sequence in Range.new(1, 1_000_000)
    end

    test "provenance names the mapping rule, its version hash, and the raw record" do
      # §5.3/§1.4: the mapping that produced the event is reconstructable
      # from the row alone.
      assert MapSet.subset?(
               @example_event.provenance |> Map.keys() |> MapSet.new(),
               MapSet.new([:mapping_name, :mapping_version_hash, :source_record_id])
             )

      assert MapSet.subset?(
               MapSet.new([:mapping_name, :mapping_version_hash, :source_record_id]),
               @example_event.provenance |> Map.keys() |> MapSet.new()
             )

      assert is_binary(@example_event.provenance.mapping_version_hash)
      assert byte_size(@example_event.provenance.mapping_version_hash) == 8
    end

    test "supersedes_event_id is nullable, and the correction shape sets it" do
      assert @example_event.supersedes_event_id == nil
      assert is_binary(@correction_event.supersedes_event_id)

      # The correction is a NEW row: same truth time (the fact happened at
      # 14:03), later observation, higher sequence, the original's id in
      # supersedes_event_id. The original is never rewritten (§7).
      assert @correction_event.occurred_at == @example_event.occurred_at
      assert DateTime.compare(@correction_event.observed_at, @example_event.observed_at) == :gt
      assert @correction_event.sequence > @example_event.sequence
      assert @correction_event.delivery_key != @example_event.delivery_key
    end

    test "region and residency_tag are first-class on every row" do
      # §6: per-region chains, locks, sequences, cursors key off region;
      # residency is checked at land, refuse-until-tagged (ADR 0042).
      assert Map.has_key?(@example_event, :region)
      assert Map.has_key?(@example_event, :residency_tag)

      # The row's residency tag names its region's jurisdiction:
      assert @example_event.residency_tag =~ ~r/\A[a-z]{2}\z/
      assert String.to_existing_atom(@example_event.residency_tag) == @example_event.region
    end
  end
end
