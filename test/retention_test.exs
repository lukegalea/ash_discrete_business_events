# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.RetentionTest do
  @moduledoc """
  Retention & GDPR for the raw layer (§9 risk 5): the partitioned raw
  table, drop-partition purge as an explicit audited operator action
  (ledger tombstones, structural facts only), erasure-as-event, and the
  PII lint. Explicitly does NOT resolve ADR 0024 platform-wide.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshDiscreteBusinessEvents.Fixtures.{Ledger, SourceRecord}
  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Retention
  alias AshDiscreteBusinessEvents.Test.Repo

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    :ok
  end

  # ── the partition strategy ─────────────────────────────────────────────

  describe "the partitioned raw layer" do
    test "landings route to the month's partition; the DEFAULT catches unsliced months" do
      # An October observation (the fixture year has an explicit October).
      Retention.ensure_partition!(SourceRecord, "2026-10")

      oct =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: "retention-oct-1",
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Proposal"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-01T00:00:00+0000"},
          fetched_at: ~U[2026-10-01 10:00:00Z]
        })

      # A February observation — the partition is ensured explicitly.
      Retention.ensure_partition!(SourceRecord, "2026-02")

      feb =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: "retention-feb-1",
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Won"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-02-01T00:00:00+0000"},
          fetched_at: ~U[2026-02-01 10:00:00Z]
        })

      assert partition_of(oct.id) == "source_records_2026_10"
      assert partition_of(feb.id) == "source_records_2026_02"
    end

    test "ensure_partition! is idempotent and creates the identity exclusion" do
      assert :ok = Retention.ensure_partition!(SourceRecord, "2026-03")
      assert :ok = Retention.ensure_partition!(SourceRecord, "2026-03")

      %{rows: rows} =
        Repo.query!(
          "SELECT count(*) FROM pg_constraint WHERE conname = 'source_records_2026_03_identity_excl'"
        )

      assert rows == [[1]]
    end
  end

  # ── drop-partition purge ───────────────────────────────────────────────

  describe "purge_before" do
    test "refuses without explicit confirmation" do
      assert {:error, :unconfirmed} =
               Retention.purge_before(SourceRecord, Ledger,
                 before: ~U[2026-03-01 00:00:00Z],
                 region: :us
               )
    end

    test "drops old partitions, records structural tombstones, keeps everything else" do
      Retention.ensure_partition!(SourceRecord, "2026-01")

      # An OLD observation (droppable: the partition ends Feb 1) …
      old =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: "retention-old-1",
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Prospecting"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-01-15T00:00:00+0000"},
          fetched_at: ~U[2026-01-15 10:00:00Z]
        })

      # …and a NEW one (kept: its partition ends long after the cutoff).
      kept =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: "retention-keep-1",
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Won"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-01T00:00:00+0000"},
          fetched_at: ~U[2026-10-01 10:00:00Z]
        })

      # The cutoff April 1: January, February AND March partitions end
      # at/before it (the migration slices the whole fixture year).
      assert {:ok, %{dropped: dropped, rows: rows, tombstones: tombstones}} =
               Retention.purge_before(
                 SourceRecord,
                 Ledger,
                 before: ~U[2026-04-01 00:00:00Z],
                 region: :us,
                 confirmed: true
               )

      assert dropped == [
               "source_records_2026_01",
               "source_records_2026_02",
               "source_records_2026_03"
             ]

      assert rows == 1
      assert tombstones == 3

      # The old rows are GONE; the new ones stand.
      assert SourceRecord
             |> Ash.Query.filter(external_id == ^old.external_id)
             |> Ash.read!(authorize?: false) == []

      kept_row =
        SourceRecord
        |> Ash.Query.filter(external_id == ^kept.external_id)
        |> Ash.read_one!(authorize?: false)

      assert kept_row.id == kept.id

      # The tombstone: a ledger row carrying STRUCTURAL facts only.
      tombstones =
        Ledger.by_subject!(:us, "source_records_2026_01")

      assert length(tombstones) == 1

      tombstone = hd(tombstones)
      assert tombstone.action == :"retention.partition_purged"
      assert tombstone.data == %{"partition" => "source_records_2026_01", "rows" => 1}
      refute Map.has_key?(tombstone.data, "payload")
    end

    test "the DEFAULT partition is never dropped" do
      # Land WITHOUT ensuring a month — the row falls into the DEFAULT.
      _ =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: "retention-default-1",
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Won"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2030-01-01T00:00:00+0000"},
          fetched_at: ~U[2030-01-01 10:00:00Z]
        })

      # A 2030 fetch lives in the DEFAULT partition (all explicit months
      # end 2027-01) — the purge drops every explicit old month but
      # NEVER the DEFAULT (mixed data; purge it consciously by erasure).
      assert {:ok, %{dropped: dropped}} =
               Retention.purge_before(
                 SourceRecord,
                 Ledger,
                 before: ~U[2031-01-01 00:00:00Z],
                 region: :us,
                 confirmed: true
               )

      assert "source_records_default" not in dropped
      assert length(dropped) == 12

      assert %{rows: [[default_rows]]} =
               Repo.query!("SELECT count(*) FROM source_records_default")

      assert default_rows == 1
    end
  end

  # ── erasure-as-event ───────────────────────────────────────────────────

  describe "erase_subject" do
    test "tombstones first, deletes the raw rows, and the ledger row stays" do
      subject = "retention-erase-1"

      _ =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: subject,
          region: :us,
          residency_tag: "us",
          raw_payload: %{"email" => "victim@example.com", "stage" => "Proposal"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-01T00:00:00+0000"},
          fetched_at: ~U[2026-10-01 10:00:00Z]
        })

      _ =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: subject,
          region: :us,
          residency_tag: "us",
          raw_payload: %{"email" => "victim@example.com", "stage" => "Won"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-02T00:00:00+0000"},
          fetched_at: ~U[2026-10-02 10:00:00Z]
        })

      # A REAL ledger event for the subject (PII-minimal canonical data).
      real_event =
        Ledger.record!(%{
          event_kind: :"opportunity.stage_changed",
          region: :us,
          residency_tag: "us",
          subject_type: "crm.opportunity",
          subject_external_id: subject,
          occurred_at: ~U[2026-10-01 10:00:00Z],
          provenance: %{
            "mapping_name" => "opportunity_stage_changed",
            "mapping_version_hash" => "abcdef12",
            "source_record_id" => nil
          },
          data: %{"stage" => "Proposal"}
        })

      assert {:ok, %{deleted: 2}} =
               Retention.erase_subject(SourceRecord, Ledger, :us, subject)

      # The raw rows are GONE…
      raws =
        SourceRecord
        |> Ash.Query.filter(external_id == ^subject)
        |> Ash.read!(authorize?: false)

      assert raws == []

      # …the tombstone stands (the ledger's native answer to GDPR)…
      tombstone =
        Ledger.by_subject!(:us, subject)
        |> Enum.find(&(&1.action == :"retention.subject_erased"))

      assert tombstone.action == :"retention.subject_erased"
      assert tombstone.data == %{"subject" => subject, "region" => "us"}

      # …and the REAL ledger event stays: its canonical data is
      # PII-minimal by design (BIZEV-5's mapping rules).
      kept =
        Ledger.by_subject!(:us, subject)
        |> Enum.find(&(&1.id == real_event.id))

      assert kept.data["stage"] == "Proposal"
    end

    test "re-sync after erasure re-lands as NEW history — never a resurrection" do
      subject = "retention-erase-2"

      _ =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: subject,
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Proposal"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-01T00:00:00+0000"},
          fetched_at: ~U[2026-10-01 10:00:00Z]
        })

      assert {:ok, %{deleted: 1}} = Retention.erase_subject(SourceRecord, Ledger, :us, subject)

      # The next sync re-observes the subject's CURRENT source state — as
      # a fresh observation at the fetch instant. The erased instants do
      # not come back.
      relanded =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: subject,
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Proposal"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-05T00:00:00+0000"},
          fetched_at: ~U[2026-10-05 10:00:00Z]
        })

      assert relanded.valid_at.lower == ~U[2026-10-05 10:00:00.000000Z]

      # The as-of read BEFORE the re-landing answers honestly: the
      # subject's earlier history is erased, not archived.
      historical =
        SourceRecord
        |> Ash.Query.filter(external_id == ^subject)
        |> Ash.Query.as_of(~U[2026-10-02 12:00:00Z])
        |> Ash.read!(authorize?: false)

      assert historical == []
    end

    test "the host's context and record opts reach the tombstone" do
      subject = "retention-erase-3"

      _ =
        SourceRecord.land!(%{
          source: :salesforce,
          stream: :opportunity,
          external_id: subject,
          region: :us,
          residency_tag: "us",
          raw_payload: %{"stage" => "Proposal"},
          source_metadata: %{"adapter" => "retention-test"},
          cursor: %{"system_modstamp" => "2026-10-01T00:00:00+0000"},
          fetched_at: ~U[2026-10-01 10:00:00Z]
        })

      # The fixture ledger refuses a blocked actor at the append: the
      # record opts reach the tombstone's record, and since the tombstone
      # is recorded FIRST, a refused tombstone deletes nothing.
      assert_raise Ash.Error.Forbidden, fn ->
        Retention.erase_subject(SourceRecord, Ledger, :us, subject,
          record_opts: [actor: %{blocked?: true}]
        )
      end

      assert [_still_there] =
               SourceRecord
               |> Ash.Query.filter(external_id == ^subject)
               |> Ash.read!(authorize?: false)

      assert {:ok, %{deleted: 1}} =
               Retention.erase_subject(SourceRecord, Ledger, :us, subject,
                 context: %{"owner" => "host-owner"},
                 residency_tag: "us-east",
                 record_opts: [actor: %{blocked?: true}, authorize?: false]
               )

      tombstone =
        Ledger.by_subject!(:us, subject)
        |> Enum.find(&(&1.action == :"retention.subject_erased"))

      assert tombstone.context == %{"owner" => "host-owner"}
      assert tombstone.residency_tag == "us-east"
    end
  end

  describe "tombstone/5" do
    test "is the tombstone's record input, as data" do
      assert Retention.tombstone(:"retention.subject_erased", :us, "subject-1", %{"n" => 1},
               occurred_at: ~U[2026-10-18 00:00:00Z],
               context: %{"owner" => "o"},
               delivery_key: "erased:subject-1"
             ) == %{
               event_kind: :"retention.subject_erased",
               region: :us,
               residency_tag: "us",
               subject_type: "retention",
               subject_external_id: "subject-1",
               occurred_at: ~U[2026-10-18 00:00:00Z],
               provenance: %{
                 "mapping_name" => "retention",
                 "mapping_version_hash" => "retention",
                 "source_record_id" => nil
               },
               data: %{"n" => 1},
               context: %{"owner" => "o"},
               delivery_key: "erased:subject-1"
             }

      assert Retention.tombstone_kinds() == [
               :"retention.partition_purged",
               :"retention.subject_erased"
             ]
    end

    test "refuses a kind that is not a tombstone" do
      # Read at run time, so the type checker does not flag the deliberate
      # mismatch at compile time.
      kind = Process.get(:not_a_tombstone, :"opportunity.stage_changed")

      assert_raise FunctionClauseError, fn ->
        Retention.tombstone(kind, :us, "s", %{})
      end
    end
  end

  # ── the PII lint ───────────────────────────────────────────────────────

  describe "the mapping PII lint" do
    test "an obvious PII canonical target is refused at compile time" do
      assert_raise Spark.Error.DslError, ~r/looks like direct personal data/, fn ->
        defmodule Host.PiiMapping do
          use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

          business_events do
            source :s do
              region(:us)
              stream(:t)
            end

            mapping :pii_leak do
              source {:s, :t}

              map(:email, from: "Email", type: :string)
              map(:occurred_at, from: "At", type: :utc_datetime_usec)
            end
          end
        end
      end
    end

    test "unmapped_because remains the documented way to name a PII gap" do
      defmodule Host.UnmappedPii do
        use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

        business_events do
          source :s do
            region(:us)
            stream(:t)
          end

          mapping :honest do
            source {:s, :t}

            map(:stage, from: "Stage", type: :string)
            map(:occurred_at, from: "At", type: :utc_datetime_usec)

            unmapped_because(:owner_email, "PII — raw layer only (§9 risk 5)")
          end
        end
      end

      mapping = Info.mapping(Host.UnmappedPii, :honest)
      assert Enum.any?(mapping.ops, &(&1.target == :owner_email))
    end
  end

  defp partition_of(record_id) do
    %{rows: [[name]]} =
      Repo.query!(
        "SELECT tableoid::regclass::text FROM source_records WHERE id = $1",
        [Ecto.UUID.dump!(record_id)]
      )

    name
  end
end
