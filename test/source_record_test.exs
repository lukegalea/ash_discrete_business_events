# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecordTest do
  @moduledoc """
  The §1.3 land-path contracts: the identity tuple (two streams, same
  external id, two records — the E1 gap fix), no-op-on-identical,
  new-period-on-change, and zone/residency admission refusing at land.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Observations
  alias AshDiscreteBusinessEvents.Fixtures.SourceRecord
  alias AshDiscreteBusinessEvents.SourceRecord.AdmissionRefused

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{external_id: Observations.external_id()}
  end

  describe "land" do
    test "opens a period at the observation instant", %{external_id: external_id} do
      record = Observations.land!(external_id: external_id)

      assert record.source == :salesforce
      assert record.stream == :opportunity
      assert record.external_id == external_id
      assert record.region == :us
      assert record.residency_tag == "us"
      assert record.raw_payload["StageName"] == "Qualification"
      assert record.fetched_at == ~U[2026-10-01 14:09:41.000000Z]

      # The period opens at the observation instant and stays open:
      # `valid_at = [fetched_at, next observation)` — knowledge time is
      # the raw layer's dimension (§1.3).
      assert record.valid_at.lower == ~U[2026-10-01 14:09:41.000000Z]
      assert record.valid_at.upper == nil

      # recorded_at is the wall clock of the write — the temporal
      # machinery's stamp, present and recent.
      assert %DateTime{} = record.recorded_at
    end

    test "two streams, same external id, two records — stream is IN the identity (E1 fix)", %{
      external_id: external_id
    } do
      opportunity = Observations.land!(external_id: external_id, stream: :opportunity)
      account = Observations.land!(external_id: external_id, stream: :account)

      assert opportunity.id != account.id

      assert SourceRecord.by_identity!(:salesforce, :opportunity, external_id, :us).id ==
               opportunity.id

      assert SourceRecord.by_identity!(:salesforce, :account, external_id, :us).id == account.id
    end

    test "region is IN the identity — same id, other region, another record (§6)", %{
      external_id: external_id
    } do
      us = Observations.land!(external_id: external_id, region: :us)
      ca = Observations.land!(external_id: external_id, region: :ca, residency_tag: "ca")

      assert us.id != ca.id
      assert SourceRecord.by_identity!(:salesforce, :opportunity, external_id, :ca).id == ca.id
    end

    test "re-observing identical content is a temporal no-op (the VPM-49 pattern)", %{
      external_id: external_id
    } do
      first = Observations.land!(external_id: external_id)
      again = Observations.land!(external_id: external_id)

      # Nothing was written: the same record comes back.
      assert again.id == first.id
      assert again.valid_at.lower == first.valid_at.lower

      assert length(Observations.history(external_id)) == 1
    end

    test "atom-keyed and string-keyed payloads that decode alike are the same observation", %{
      external_id: external_id
    } do
      first = Observations.land!(external_id: external_id)

      again =
        Observations.land!(
          external_id: external_id,
          raw_payload: %{
            Id: external_id,
            StageName: "Qualification",
            SystemModstamp: "2026-10-01T14:03:00.000+0000"
          }
        )

      assert again.id == first.id
      assert length(Observations.history(external_id)) == 1
    end

    test "changed content opens a new period; history is never overwritten", %{
      external_id: external_id
    } do
      t1 = ~U[2026-10-01 14:09:41.000000Z]
      t2 = ~U[2026-10-02 08:15:12.000000Z]

      first = Observations.land!(external_id: external_id, fetched_at: t1)

      changed =
        Observations.land!(
          external_id: external_id,
          fetched_at: t2,
          raw_payload: %{
            "Id" => external_id,
            "StageName" => "Negotiation",
            "SystemModstamp" => "2026-10-02T07:58:12.000+0000"
          }
        )

      history = Observations.history(external_id)
      assert length(history) == 2

      # Versions share the record's primary key — the periods are the
      # history.
      assert changed.id == first.id

      [older, newer] = history
      assert older.raw_payload["StageName"] == "Qualification"
      assert newer.raw_payload["StageName"] == "Negotiation"

      # The old period closed exactly at the new observation instant;
      # the new one is open.
      assert older.valid_at.lower == t1
      assert older.valid_at.upper == t2
      assert newer.valid_at.lower == t2
      assert newer.valid_at.upper == nil
    end

    test "a late-arriving duplicate of already-observed content is a no-op", %{
      external_id: external_id
    } do
      t1 = ~U[2026-10-01 14:09:41.000000Z]
      t15 = ~U[2026-10-01 17:30:00.000000Z]
      t2 = ~U[2026-10-02 08:15:12.000000Z]

      Observations.land!(external_id: external_id, fetched_at: t1)

      Observations.land!(
        external_id: external_id,
        fetched_at: t2,
        raw_payload: %{
          "Id" => external_id,
          "StageName" => "Negotiation",
          "SystemModstamp" => "2026-10-02T07:58:12.000+0000"
        }
      )

      # A delayed tap pass re-delivers the t1 content, observed at t1.5:
      # the version valid AT t1.5 carries the same payload and cursor, so
      # nothing is written.
      late = Observations.land!(external_id: external_id, fetched_at: t15)

      assert late.raw_payload["StageName"] == "Qualification"
      assert length(Observations.history(external_id)) == 2
    end

    test "landing before known history is refused, loudly", %{external_id: external_id} do
      Observations.land!(external_id: external_id, fetched_at: ~U[2026-10-02 08:15:12.000000Z])

      error =
        assert_raise Ash.Error.Invalid, fn ->
          Observations.land!(
            external_id: external_id,
            fetched_at: ~U[2026-10-01 14:09:41.000000Z]
          )
        end

      assert Exception.message(error) =~ "earlier than"
      assert Exception.message(error) =~ "known history"
      assert length(Observations.history(external_id)) == 1
    end

    test "an untagged observation is refused — refuse until tagged" do
      error =
        assert_raise Ash.Error.Invalid, fn ->
          SourceRecord.land!(Observations.observation(residency_tag: nil))
        end

      # The argument is required; the admission change's own nil-guard
      # backs the action-level refusal for direct `:open_period` use.
      assert Exception.message(error) =~ "residency_tag"
    end

    test "a tag that does not admit into the target region is refused (ADR 0042)" do
      error =
        assert_raise Ash.Error.Forbidden, fn ->
          Observations.land!(region: :us, residency_tag: "ca")
        end

      assert %AdmissionRefused{} = hd(error.errors)
      assert Exception.message(hd(error.errors)) =~ "does not admit into"
    end

    test "residency is fixed at admission — the tag rides every version", %{
      external_id: external_id
    } do
      first = Observations.land!(external_id: external_id, residency_tag: "us")

      changed =
        Observations.land!(
          external_id: external_id,
          fetched_at: ~U[2026-10-02 08:15:12.000000Z],
          raw_payload: %{"Id" => external_id, "StageName" => "Negotiation"}
        )

      # Content changes re-open periods; admission is not re-litigated.
      assert first.residency_tag == "us"
      assert changed.residency_tag == "us"
    end
  end
end
