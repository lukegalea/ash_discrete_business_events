# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecordIdentityContractTest do
  @moduledoc """
  The SourceRecord identity and raw-layer contract, pinned as data
  (design §1.3).

  BIZEV-2 ships no SourceRecord resource — that is BIZEV-3. What this
  slice owes the design is the *shape freeze*: the identity tuple —
  `(source, stream, external_id, region)`, period-aware — plus the raw
  layer's other structural rulings, locked here as fixtures so BIZEV-3's
  resource either matches the contract or this test fails.

  The identity is the design's fix for the E1 known gap (two streams,
  same external id, one row): stream and region live *in* the identity,
  structurally — not by projector-side filtering, not by convention.
  """

  use ExUnit.Case, async: true

  # ── The identity tuple (§1.3) ──────────────────────────────────────────
  # Period-aware `WITHOUT OVERLAPS` on these four: what landed, in which
  # stream, carrying which external id, admitted into which region.

  @identity_source :salesforce
  @identity_stream :opportunity
  @identity_external_id "0065f000003Xy7ZAAS"
  @identity_region :us

  @identity_tuple {@identity_source, @identity_stream, @identity_external_id, @identity_region}

  @spec identity_tuple :: {atom(), atom(), String.t(), atom()}
  defp identity_tuple, do: @identity_tuple

  # ── The raw layer's row facts (§1.3, §2) ───────────────────────────────
  # The dogfood's SourceObject, upgraded: immutable payload per version,
  # cursor-as-data, observed-vs-truth split at the raw layer too.

  @raw_version %{
    identity: @identity_tuple,
    payload: %{
      "Id" => "0065f000003Xy7ZAAS",
      "Name" => "Northwind — Phase 2",
      "StageName" => "Proposal",
      "Amount" => 95_000.00,
      "SystemModstamp" => "2026-10-01T14:03:00.000+0000",
      "LastModifiedById" => "0055f000001AbCdAAF"
    },
    # Knowledge time is the raw layer's dimension (the period basis);
    # truth time (SystemModstamp) lives in the payload and is extracted
    # by mapping into the ledger's occurred_at.
    fetched_at: ~U[2026-10-01 14:09:41Z],
    valid_from: ~U[2026-10-01 14:09:41Z],
    valid_until: nil,
    residency_tag: "us",
    cursor: %{"system_modstamp" => "2026-10-01T14:09:30.000+0000"}
  }

  # The same identity, re-observed with IDENTICAL content: a no-op (the
  # VPM-49 import-rework pattern) — no new period, no ledger event.
  @identical_reobservation @raw_version

  # The same identity, re-observed with CHANGED content: a NEW period
  # (version history preserved — never upsert-in-place, ADR 0049).
  @changed_reobservation %{
    @raw_version
    | payload: %{
        "Id" => "0065f000003Xy7ZAAS",
        "Name" => "Northwind — Phase 2",
        "StageName" => "Negotiation",
        "Amount" => 97_500.00,
        "SystemModstamp" => "2026-10-02T07:58:12.000+0000",
        "LastModifiedById" => "0055f000001AbCdAAF"
      },
      fetched_at: ~U[2026-10-02 08:15:12Z],
      valid_from: ~U[2026-10-02 08:15:12Z],
      valid_until: nil,
      cursor: %{"system_modstamp" => "2026-10-02T08:15:00.000+0000"}
  }

  # The same external id observed in a DIFFERENT stream: a different
  # record — the E1 gap, fixed structurally (§1.3).
  @other_stream_identity {@identity_source, :account, @identity_external_id, @identity_region}

  describe "the identity tuple" do
    test "it is a four-element tuple — source, stream, external_id, region" do
      assert tuple_size(identity_tuple()) == 4

      {source, stream, external_id, region} = identity_tuple()
      assert Enum.all?([source, stream, region], &is_atom/1)

      # The fixture's external id is a Salesforce opportunity id — the
      # `006`-prefixed key form (15 or 18 chars).
      assert external_id =~ ~r/\A006[0-9A-Za-z]{12}(?:[0-9A-Za-z]{3})?\z/
    end

    test "stream is IN the identity — two streams, same external id, two records (E1 fix)" do
      identity = identity_tuple() |> Tuple.to_list()
      other = @other_stream_identity |> Tuple.to_list()

      # Same source, external id and region; different stream element:
      assert Enum.at(other, 0) == Enum.at(identity, 0)
      assert Enum.at(other, 2) == Enum.at(identity, 2)
      assert Enum.at(other, 3) == Enum.at(identity, 3)
      assert Enum.at(other, 1) == :account
      assert Enum.at(identity, 1) == :opportunity

      # The other stream's name is not in the real identity — a record
      # is only ever in the stream that landed it.
      refute Enum.member?(identity, :account)
    end

    test "region is IN the identity — CA and US never merge silently (§6)" do
      identity = identity_tuple() |> Tuple.to_list()
      ca_twin = identity_tuple() |> put_elem(3, :ca) |> Tuple.to_list()

      assert Enum.at(ca_twin, 0) == Enum.at(identity, 0)
      assert Enum.at(ca_twin, 1) == Enum.at(identity, 1)
      assert Enum.at(ca_twin, 2) == Enum.at(identity, 2)
      assert Enum.at(ca_twin, 3) == :ca

      refute Enum.member?(identity, :ca)
    end
  end

  describe "the raw version contract" do
    test "the payload is the verbatim external observation, immutable per version" do
      # §2.1: raw-payload immutability at the boundary — versions preserve
      # every observed payload byte-for-byte; canonical rows derive,
      # never replace. (The payload here is the fixture's SOQL row, keys
      # exactly as the external API returned them.)
      assert is_map(@raw_version.payload)
      assert Map.has_key?(@raw_version.payload, "SystemModstamp")
    end

    test "knowledge time is the raw layer's dimension; truth time stays in the payload (§1.3)" do
      # fetched_at is the period basis; the source-side truth time is
      # extracted by the mapping (BIZEV-5) into the ledger's occurred_at.
      assert %DateTime{} = @raw_version.fetched_at
      assert @raw_version.payload["SystemModstamp"] == "2026-10-01T14:03:00.000+0000"
    end

    test "validity is temporal-extension periods, never hand-rolled columns (§4)" do
      # valid_at = [observed_at, next observation): the OPEN period has a
      # nil end, and the period opens at observation. A closed end only
      # ever appears when a later version of the same identity lands.
      assert @raw_version.valid_until == nil
      assert DateTime.compare(@raw_version.valid_from, @raw_version.fetched_at) == :eq

      # The changed re-observation closes the earlier period at its own
      # fetched_at and opens a new one — history preserved, in periods:
      changed_closes_prior = @changed_reobservation.fetched_at
      assert @raw_version.valid_until == nil
      assert DateTime.compare(changed_closes_prior, @raw_version.valid_from) == :gt
    end

    test "identical re-observation is a no-op; changed content opens a new period (§2.5)" do
      # §2.5: upsert-idempotency at the SOURCE layer — re-running a sync
      # is a no-op when content is unchanged, not a duplicate factory.
      # §1.3: changed content opens a new period. BIZEV-3's land action
      # must implement exactly this split.
      assert @identical_reobservation == @raw_version
      assert @changed_reobservation.payload != @raw_version.payload

      assert DateTime.compare(
               @changed_reobservation.valid_from,
               @raw_version.valid_from
             ) == :gt
    end

    test "the cursor is data on the raw row, never a job arg (§2.3)" do
      cursor = @raw_version.cursor
      assert is_map(cursor)
      assert Map.has_key?(cursor, "system_modstamp")
    end

    test "residency is tagged on the raw row — admission checked at land (§1.3, ADR 0042)" do
      tag = @raw_version.residency_tag

      # The tag names the region's jurisdiction code, and the raw row's
      # region element agrees with it; the land action refuses until
      # tagged.
      assert tag =~ ~r/\A[a-z]{2}\z/
      assert String.to_existing_atom(tag) == elem(@raw_version.identity, 3)
    end
  end
end
