# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingVersionTest do
  @moduledoc """
  The versioned-artifact lifecycle (draft → validate → activate) and the
  rule-version-pinned replay proof: vN over an observation sequence
  yields identical outputs on every application, and vN+1 differs only
  where its operators differ.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.{Host, MappingVersion, Observations}
  alias AshDiscreteBusinessEvents.Mappings
  alias AshDiscreteBusinessEvents.Mappings.Compiler
  alias AshDiscreteBusinessEvents.Test.Repo

  import Ecto.Query, only: [from: 2]

  @moduletag :db

  # A second revision of the SAME mapping name: the fixture's operators,
  # plus one concat. Applying it must change the output ONLY by the new
  # target key — everywhere else, byte-identical to v1.
  defmodule V2Host do
    @moduledoc "v1's rule with one more operator — the vN+1 of the replay proof."

    use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

    business_events do
      source :salesforce do
        region(:us)
        stream(:opportunity)
      end

      mapping :opportunity_stage_changed do
        source {:salesforce, :opportunity}

        map(:stage, from: "StageName", type: :string)
        map(:amount, from: "Amount", type: :integer)
        map(:occurred_at, from: "SystemModstamp", type: :utc_datetime_usec)

        concat(:label, from: ["Name", "StageName"], separator: " / ")

        unmapped_because(:owner_email, "PII — kept out of canonical events (§9.5)")
      end
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # This file owns the table: clear any rows a previous (non-sandboxed)
    # run left behind, so publish's content-addressing starts empty.
    Repo.delete_all(MappingVersion)

    :ok
  end

  defp stage_sequence do
    # Three observations of one opportunity's life — the observation
    # sequence the replay proof applies versions over.
    stages = [
      {"Qualification", ~U[2026-10-01 14:03:00.000000Z]},
      {"Negotiation", ~U[2026-10-04 09:30:00.000000Z]},
      {"Closed Won", ~U[2026-10-09 17:45:00.000000Z]}
    ]

    Enum.map(stages, fn {stage, modstamp} ->
      Observations.land!(
        raw_payload: %{
          "Id" => "0065f000003Xy7ZAAS",
          "Name" => "Acme renewal",
          "StageName" => stage,
          "Amount" => 42_000,
          "SystemModstamp" => DateTime.to_iso8601(modstamp)
        }
      )
    end)
  end

  defp publish_and_activate(host, name, resource) do
    {:ok, version} = Mappings.publish(host, name, resource)
    {:ok, validated} = MappingVersion.validate_version(version)
    Mappings.activate!(validated)
  end

  defp apply_over(version, records) do
    Enum.map(records, fn record ->
      assert {:ok, canonical} =
               Mappings.run(version, record.raw_payload, source_record_id: record.external_id)

      canonical
    end)
  end

  # ── publish: content-addressed, idempotent ────────────────────────────

  describe "publish" do
    test "records the declared mapping as a draft version" do
      {:ok, version} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)

      assert version.status == :draft
      assert version.mapping_name == "opportunity_stage_changed"
      assert version.source_name == :salesforce
      assert version.stream_name == :opportunity
      assert version.version_hash =~ ~r/^[0-9a-f]{8}$/

      # The artifact is stored in declaration order — the hash's input.
      assert Enum.map(version.artifact["ops"], & &1["target"]) == [
               "stage",
               "amount",
               "occurred_at",
               "owner_email"
             ]
    end

    test "is content-addressed: publishing the same declaration returns the same row" do
      {:ok, first} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)
      {:ok, second} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)

      assert first.id == second.id
    end

    test "a changed declaration mints a NEW version row — history is never overwritten" do
      {:ok, v1} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)
      {:ok, v2} = Mappings.publish(V2Host, :opportunity_stage_changed, MappingVersion)

      assert v1.id != v2.id
      assert v1.version_hash != v2.version_hash

      assert MappingVersion.by_name_and_hash!("opportunity_stage_changed", v1.version_hash).id ==
               v1.id

      assert MappingVersion.by_name_and_hash!("opportunity_stage_changed", v2.version_hash).id ==
               v2.id
    end

    test "the provenance invariant: version_hash == hash(stored artifact)" do
      {:ok, v1} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)
      {:ok, v2} = Mappings.publish(V2Host, :opportunity_stage_changed, MappingVersion)

      for version <- [v1, v2] do
        assert Compiler.hash(version.artifact) == version.version_hash
      end
    end

    test "an unknown mapping name is refused" do
      assert {:error, message} = Mappings.publish(Host, :no_such_mapping, MappingVersion)
      assert message =~ "no declared mapping"
    end
  end

  # ── lifecycle: draft → validate → activate ────────────────────────────

  describe "lifecycle" do
    test "validate re-runs the compiler's checks over the STORED artifact and marks :validated" do
      {:ok, version} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)

      assert {:ok, validated} = MappingVersion.validate_version(version)
      assert validated.status == :validated
    end

    test "validate proves the ROW: a drifted stored artifact is refused loudly" do
      {:ok, version} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)

      # Corrupt the artifact under the row — as a hand-edit or a migration
      # bug would. Validation must catch the row, not the declaration.
      tampered = Map.update!(version.artifact, "ops", &List.delete_at(&1, 2))

      Repo.update_all(
        from(v in MappingVersion, where: v.id == ^version.id),
        set: [artifact: tampered]
      )

      reloaded = MappingVersion.by_id!(version.id)
      assert reloaded.artifact != version.artifact

      assert {:error, error} = MappingVersion.validate_version(reloaded)
      message = Exception.message(error)
      assert message =~ "occurred_at"
    end

    test "the lifecycle is forward-only: activate refuses a draft, validate refuses a validated" do
      {:ok, version} = Mappings.publish(Host, :opportunity_stage_changed, MappingVersion)

      assert_raise ArgumentError, ~r/only a :validated version can activate/, fn ->
        Mappings.activate!(version)
      end

      {:ok, validated} = MappingVersion.validate_version(version)

      assert {:error, _} = MappingVersion.validate_version(validated)
    end

    test "activate is the pointer move: the previous active is demoted, never rewritten" do
      v1 = publish_and_activate(Host, :opportunity_stage_changed, MappingVersion)

      assert MappingVersion.active!("opportunity_stage_changed").id == v1.id
      assert v1.status == :active

      v2 = publish_and_activate(V2Host, :opportunity_stage_changed, MappingVersion)

      # The name's active pointer moved to v2…
      assert MappingVersion.active!("opportunity_stage_changed").id == v2.id
      assert v2.status == :active

      # …v1 stepped back to :validated — its content exactly as proven.
      demoted = MappingVersion.by_id!(v1.id)
      assert demoted.status == :validated
      assert demoted.artifact == v1.artifact
      assert demoted.version_hash == v1.version_hash
    end

    test "the active read resolves one row per name — the provenance join's contract" do
      assert Mappings.active_version(MappingVersion, :opportunity_stage_changed) == nil

      v1 = publish_and_activate(Host, :opportunity_stage_changed, MappingVersion)

      assert Mappings.active_version(MappingVersion, :opportunity_stage_changed).id == v1.id
    end
  end

  # ── the replay proof ──────────────────────────────────────────────────

  describe "rule-version-pinned replay" do
    test "vN over an observation sequence ⇒ identical outputs; vN+1 differs only where operators differ" do
      records = stage_sequence()

      v1 = publish_and_activate(Host, :opportunity_stage_changed, MappingVersion)
      outputs_v1 = apply_over(v1, records)

      # The proof's first half: apply vN again — through the SAME artifact
      # and through its content address — and the outputs are identical.
      refetched_v1 =
        MappingVersion.by_name_and_hash!("opportunity_stage_changed", v1.version_hash)

      assert refetched_v1.id == v1.id
      assert apply_over(refetched_v1, records) == outputs_v1

      # vN+1: the same rule with one more operator, activated as the
      # name's new pointer.
      v2 = publish_and_activate(V2Host, :opportunity_stage_changed, MappingVersion)
      assert v1.version_hash != v2.version_hash
      outputs_v2 = apply_over(v2, records)

      # The proof's second half: vN+1 differs ONLY where its operators
      # differ — each output gains exactly the new target key, and
      # everything else (kind, occurred_at, prior data, provenance name)
      # is identical to vN.
      assert length(outputs_v1) == length(outputs_v2)

      Enum.zip(outputs_v1, outputs_v2)
      |> Enum.each(fn {out1, out2} ->
        assert Map.drop(out2.data, ["label"]) == out1.data
        assert out2.event_kind == out1.event_kind
        assert out2.occurred_at == out1.occurred_at
        assert out2.unmapped == out1.unmapped
        assert out2.provenance["mapping_name"] == out1.provenance["mapping_name"]
        assert out2.provenance["mapping_version_hash"] != out1.provenance["mapping_version_hash"]
      end)

      # And the superseded vN still replays EXACTLY as it did — the
      # ledger's provenance columns (mapping_name + mapping_version_hash)
      # join back to the row whose behavior is preserved, not the name's
      # current pointer.
      assert apply_over(refetched_v1, records) == outputs_v1
    end
  end
end
