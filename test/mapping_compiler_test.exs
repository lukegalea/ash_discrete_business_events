# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingCompilerTest do
  @moduledoc """
  The mapping engine's pure core (`Mappings.Compiler`): the artifact and
  its content hash (declaration order is the hash's input — ora-3
  §13.3), the structural checks (redundancy refused by name, footguns),
  the apply path (pure, clock-free, occurred-vs-observed), and the
  classifier seam.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Classifier
  alias AshDiscreteBusinessEvents.Fixtures.Host
  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Mappings.Compiler

  defp fixture_artifact do
    Host
    |> Info.mapping(:opportunity_stage_changed)
    |> Compiler.compile()
    |> elem(0)
  end

  defp salesforce_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "Id" => "0065f000003Xy7ZAAS",
        "Name" => "Acme renewal",
        "StageName" => "Qualification",
        "Amount" => 42_000,
        "SystemModstamp" => "2026-10-01T14:03:00.000+0000"
      },
      overrides
    )
  end

  # A canonical artifact for one op set over the fixture source, with the
  # mandatory occurred_at extraction already in place. Case keys are given
  # in CANONICAL form (post-compile: JSON-encoded strings) — the same form
  # storage hands back.
  defp artifact_with_ops(ops) do
    %{
      "mapping_name" => "opportunity_stage_changed",
      "source" => ["salesforce", "opportunity"],
      "ops" => [
        %{"op" => "map", "target" => "occurred_at", "from" => "T", "type" => "utc_datetime_usec"}
        | ops
      ]
    }
  end

  defp apply_ok(artifact, payload, opts \\ []) do
    assert {:ok, canonical} = Compiler.run(artifact, payload, opts)
    canonical
  end

  defp occurred_at, do: ~U[2026-10-01 14:03:00Z]

  # ── artifact & hash ───────────────────────────────────────────────────

  describe "compile" do
    test "the hash is 8 lowercase hex chars, equal to hashing the artifact" do
      {artifact, hash} = Host |> Info.mapping(:opportunity_stage_changed) |> Compiler.compile()

      assert hash == Compiler.hash(artifact)
      assert hash =~ ~r/^[0-9a-f]{8}$/
    end

    test "the artifact carries name, source, and the ops in DECLARATION order (§13.3)" do
      artifact = fixture_artifact()

      assert artifact["mapping_name"] == "opportunity_stage_changed"
      assert artifact["source"] == ["salesforce", "opportunity"]
      assert Enum.map(artifact["ops"], & &1["target"]) == [
               "stage",
               "amount",
               "occurred_at",
               "owner_email"
             ]
    end

    test "declaration order is the hash's input: reordered operators hash differently" do
      mapping = Info.mapping(Host, :opportunity_stage_changed)
      reordered = %{mapping | ops: Enum.reverse(mapping.ops)}

      {artifact, hash} = Compiler.compile(mapping)
      {reordered_artifact, reordered_hash} = Compiler.compile(reordered)

      assert hash != reordered_hash
      assert artifact["ops"] != reordered_artifact["ops"]

      # The canonical form serializes ops as a LIST — never Map iteration
      # order. First position is the first declared operator.
      assert Enum.at(artifact["ops"], 0)["target"] == "stage"
    end

    test "the hash is deterministic: the same declaration compiles to the same bytes" do
      {artifact, hash} = Host |> Info.mapping(:opportunity_stage_changed) |> Compiler.compile()
      {artifact_again, hash_again} =
        Host |> Info.mapping(:opportunity_stage_changed) |> Compiler.compile()

      assert hash == hash_again
      assert artifact == artifact_again
    end

    test "a canonical artifact is its own JSON image — the DB round-trip changes nothing" do
      artifact = fixture_artifact()
      assert artifact |> Jason.encode!() |> Jason.decode!() == artifact
    end

    test "renaming mints a different hash: the name IS the event kind" do
      mapping = Info.mapping(Host, :opportunity_stage_changed)
      {_, hash} = Compiler.compile(mapping)
      {_, renamed_hash} = Compiler.compile(%{mapping | name: :opportunity_moved})

      assert hash != renamed_hash
    end

    test "a non-JSON artifact value refuses to hash" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [],
        "poison" => fn -> :ok end
      }

      assert_raise Protocol.UndefinedError, fn -> Compiler.hash(artifact) end
    end
  end

  # ── structural verification ───────────────────────────────────────────

  describe "verify" do
    test "the fixture artifact is structurally clean" do
      assert Compiler.verify(fixture_artifact()) == :ok
    end

    test "duplicate target keys are refused BY NAME, with op and position" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [
          %{"op" => "map", "target" => "stage", "from" => "A", "type" => "string"},
          %{"op" => "map", "target" => "amount", "from" => "B", "type" => "integer"},
          %{
            "op" => "map",
            "target" => "occurred_at",
            "from" => "T",
            "type" => "utc_datetime_usec"
          },
          %{"op" => "constant", "target" => "stage", "value" => "fixed"}
        ]
      }

      assert {:error, [problem]} = Compiler.verify(artifact)
      assert problem =~ "target `stage` is written by map (op 1), constant (op 4)"
      assert problem =~ "refused by name"
    end

    test "a mapping without an occurred_at extraction is refused" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [%{"op" => "map", "target" => "stage", "from" => "A", "type" => "string"}]
      }

      assert {:error, problems} = Compiler.verify(artifact)
      assert Enum.any?(problems, &(&1 =~ "no occurred_at extraction"))
    end

    test "an occurred_at extraction without a datetime type is refused" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [%{"op" => "map", "target" => "occurred_at", "from" => "T", "type" => "string"}]
      }

      assert {:error, problems} = Compiler.verify(artifact)

      assert Enum.any?(problems, &(&1 =~ "occurred_at extraction must have a datetime type"))
    end

    test "occurred_at declared unmapped is refused — the discipline is not optional" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [
          %{
            "op" => "map",
            "target" => "occurred_at",
            "from" => "T",
            "type" => "utc_datetime_usec"
          },
          %{"op" => "unmapped_because", "target" => "occurred_at", "reason" => "nah"}
        ]
      }

      assert {:error, problems} = Compiler.verify(artifact)
      assert Enum.any?(problems, &(&1 =~ "occurred_at cannot be declared unmapped"))
    end

    test "empty coalesce/concat path lists and empty decode cases are refused" do
      artifact = %{
        "mapping_name" => "x",
        "source" => ["s", "t"],
        "ops" => [
          %{
            "op" => "map",
            "target" => "occurred_at",
            "from" => "T",
            "type" => "utc_datetime_usec"
          },
          %{"op" => "coalesce", "target" => "a", "from" => []},
          %{"op" => "concat", "target" => "b", "from" => []},
          %{"op" => "decode", "target" => "c", "from" => "C", "cases" => %{}}
        ]
      }

      assert {:error, problems} = Compiler.verify(artifact)
      assert Enum.any?(problems, &(&1 =~ "coalesce on `a` has no paths"))
      assert Enum.any?(problems, &(&1 =~ "concat on `b` has no paths"))
      assert Enum.any?(problems, &(&1 =~ "decode on `c` has no cases"))
    end
  end

  # ── the apply path ────────────────────────────────────────────────────

  describe "apply — map" do
    test "writes source paths to target keys, cast to the declared type" do
      canonical = apply_ok(fixture_artifact(), salesforce_payload())

      assert canonical.data["stage"] == "Qualification"
      assert canonical.data["amount"] == 42_000
    end

    test "an absent source path writes nothing (no silent nils)" do
      canonical = apply_ok(fixture_artifact(), salesforce_payload(%{"Amount" => nil}))

      refute Map.has_key?(canonical.data, "amount")
    end

    test "dot-separated paths reach nested payloads" do
      artifact = artifact_with_ops([
        %{
          "op" => "map",
          "target" => "stage",
          "from" => "Opportunity.StageName",
          "type" => "string"
        }
      ])

      payload = %{
        "T" => "2026-10-01T14:03:00.000+0000",
        "Opportunity" => %{"StageName" => "Negotiation"}
      }

      assert apply_ok(artifact, payload).data["stage"] == "Negotiation"
    end
  end

  describe "apply — decode" do
    test "a hit translates through the case table" do
      artifact =
        artifact_with_ops([
          %{
            "op" => "decode",
            "target" => "stage_bucket",
            "from" => "StageName",
            "cases" => %{Jason.encode!("Qualification") => "early", Jason.encode!("Closed Won") => "won"}
          }
        ])

      payload = %{"StageName" => "Closed Won", "T" => "2026-10-01T14:03:00.000+0000"}

      assert apply_ok(artifact, payload).data["stage_bucket"] == "won"
    end

    test "a present value with no case is a LOUD error, never a silent fold" do
      artifact =
        artifact_with_ops([
          %{
            "op" => "decode",
            "target" => "stage_bucket",
            "from" => "StageName",
            "cases" => %{Jason.encode!("Prospecting") => "early"}
          }
        ])

      payload = %{"StageName" => "In Trial", "T" => "2026-10-01T14:03:00.000+0000"}

      assert {:error, reason} = Compiler.run(artifact, payload)
      assert reason =~ "no case for source value"
      assert reason =~ "In Trial"
    end

    test "an absent path uses the default; with no default it is skipped" do
      with_default =
        artifact_with_ops([
          %{
            "op" => "decode",
            "target" => "stage_bucket",
            "from" => "StageName",
            "cases" => %{Jason.encode!("Prospecting") => "early"},
            "default" => "unknown"
          }
        ])

      without_default =
        artifact_with_ops([
          %{
            "op" => "decode",
            "target" => "stage_bucket",
            "from" => "StageName",
            "cases" => %{Jason.encode!("Prospecting") => "early"}
          }
        ])

      payload = %{"T" => "2026-10-01T14:03:00.000+0000"}

      assert apply_ok(with_default, payload).data["stage_bucket"] == "unknown"
      refute Map.has_key?(apply_ok(without_default, payload).data, "stage_bucket")
    end

    test "integer-keyed cases match after the JSON round-trip (canonicalization at compile time)" do
      # The canonical case keys are JSON encodings — `"1"`, not 1 — so the
      # artifact's jsonb round-trip (where object keys arrive back as
      # strings) is a no-op and applies identically to the in-memory form.
      artifact =
        artifact_with_ops([
          %{
            "op" => "decode",
            "target" => "stage_bucket",
            "from" => "StageName",
            "cases" => %{"1" => "won", "2" => "lost"}
          }
        ])

      assert artifact |> Jason.encode!() |> Jason.decode!() == artifact

      assert apply_ok(artifact, %{
               "StageName" => 1,
               "T" => "2026-10-01T14:03:00.000+0000"
             }).data["stage_bucket"] == "won"

      assert apply_ok(artifact, %{
               "StageName" => 2,
               "T" => "2026-10-01T14:03:00.000+0000"
             }).data["stage_bucket"] == "lost"
    end
  end

  describe "apply — coalesce / concat / constant" do
    @payload %{
      "T" => "2026-10-01T14:03:00.000+0000",
      "CloseDate" => "2026-11-30",
      "Name" => "Acme renewal",
      "StageName" => "Qualification"
    }

    test "coalesce writes the first non-nil value, in priority order" do
      artifact =
        artifact_with_ops([
          %{"op" => "coalesce", "target" => "close", "from" => ["Missing", "CloseDate"]}
        ])

      assert apply_ok(artifact, @payload).data["close"] == "2026-11-30"

      all_miss =
        artifact_with_ops([
          %{"op" => "coalesce", "target" => "close", "from" => ["Missing", "AlsoMissing"]}
        ])

      refute Map.has_key?(apply_ok(all_miss, @payload).data, "close")
    end

    test "concat joins non-nil parts with the separator; all-nil is skipped" do
      full =
        artifact_with_ops([
          %{
            "op" => "concat",
            "target" => "label",
            "from" => ["Name", "StageName"],
            "separator" => " / "
          }
        ])

      assert apply_ok(full, @payload).data["label"] == "Acme renewal / Qualification"

      nil_part =
        artifact_with_ops([
          %{"op" => "concat", "target" => "label", "from" => ["Missing", "StageName"], "separator" => "-"}
        ])

      assert apply_ok(nil_part, @payload).data["label"] == "Qualification"

      all_nil =
        artifact_with_ops([%{"op" => "concat", "target" => "label", "from" => ["Missing"]}])

      refute Map.has_key?(apply_ok(all_nil, @payload).data, "label")
    end

    test "constant writes its fixed value" do
      artifact =
        artifact_with_ops([%{"op" => "constant", "target" => "source_system", "value" => "salesforce"}])

      assert apply_ok(artifact, @payload).data["source_system"] == "salesforce"
    end
  end

  describe "apply — occurred-vs-observed" do
    test "occurred_at comes from the PAYLOAD and is lifted OUT of data" do
      canonical = apply_ok(fixture_artifact(), salesforce_payload())

      assert canonical.occurred_at == occurred_at()
      refute Map.has_key?(canonical.data, "occurred_at")
    end

    test "the mapping owns no clock: same artifact + payload ⇒ identical output" do
      artifact = fixture_artifact()
      payload = salesforce_payload()

      assert Compiler.run(artifact, payload, source_record_id: "sr-1") ==
               Compiler.run(artifact, payload, source_record_id: "sr-1")
    end

    test "a source value that will not cast fails the apply loudly" do
      assert {:error, reason} = Compiler.run(fixture_artifact(), %{"SystemModstamp" => "nope"})
      assert reason =~ "occurred_at"
      assert reason =~ "cast"
    end

    test "unmapped_because declarations surface as refusal-by-name, on the result" do
      canonical = apply_ok(fixture_artifact(), salesforce_payload())

      assert canonical.unmapped == %{
               "owner_email" => "PII — kept out of canonical events (§9.5)"
             }
    end
  end

  describe "apply — provenance" do
    test "provenance is the ledger row's join, ready-made" do
      {artifact, hash} = Host |> Info.mapping(:opportunity_stage_changed) |> Compiler.compile()

      canonical = apply_ok(artifact, salesforce_payload(), source_record_id: "sr-42")

      assert canonical.provenance == %{
               "mapping_name" => "opportunity_stage_changed",
               "mapping_version_hash" => hash,
               "source_record_id" => "sr-42"
             }
    end

    test "the hash of the STORED artifact re-derives the version hash it was minted under" do
      artifact = fixture_artifact()
      {_, hash} = Host |> Info.mapping(:opportunity_stage_changed) |> Compiler.compile()

      assert Compiler.hash(artifact) == hash

      canonical = apply_ok(artifact, salesforce_payload())
      assert canonical.provenance["mapping_version_hash"] == hash
    end
  end

  # ── the classifier seam ───────────────────────────────────────────────

  describe "the classifier seam" do
    setup do
      start_supervised!(Classifier)
      Classifier.script(:emit)
      :ok
    end

    test ":emit records as built" do
      canonical =
        apply_ok(fixture_artifact(), salesforce_payload(),
          classifier: Classifier,
          source_record_id: "sr-1"
        )

      assert canonical.event_kind == :opportunity_stage_changed
    end

    test "{:emit, kind} overrides the event kind — and nothing else moves" do
      Classifier.script({:emit, :opportunity_won})

      canonical = apply_ok(fixture_artifact(), salesforce_payload(), classifier: Classifier)

      assert canonical.event_kind == :opportunity_won
      assert canonical.occurred_at == occurred_at()
      assert canonical.data["stage"] == "Qualification"
    end

    test "{:skip, reason} declines the record — loudly, as a distinct result" do
      Classifier.script({:skip, "below revenue threshold"})

      assert {:ok, :skipped, "below revenue threshold"} =
               Compiler.run(fixture_artifact(), salesforce_payload(), classifier: Classifier)
    end

    test "the classifier receives the artifact, the payload, and the canonical-so-far" do
      artifact = fixture_artifact()
      payload = salesforce_payload()
      test_self = self()

      classifier = fn_classifier(fn a, p, canonical ->
        send(test_self, {:classified, a, p, canonical})
        :emit
      end)

      assert {:ok, _} = Compiler.run(artifact, payload, classifier: classifier)

      assert_receive {:classified, ^artifact, ^payload, canonical}
      assert canonical.event_kind == :opportunity_stage_changed
      assert canonical.provenance["source_record_id"] == nil
    end

    test "an invalid classifier return fails the apply loudly" do
      Classifier.script(:nonsense)

      assert {:error, {:classifier, {:invalid_return, :nonsense}}} =
               Compiler.run(fixture_artifact(), salesforce_payload(), classifier: Classifier)
    end

    test "the :classifier option wins over the artifact's classify_with" do
      artifact = Map.put(fixture_artifact(), "classify_with", Classifier)
      Classifier.script({:skip, "the artifact's classifier would skip"})

      # The option's classifier emits — and its decision is the one taken.
      canonical = apply_ok(artifact, salesforce_payload(), classifier: fn_classifier(:emit))

      assert canonical.event_kind == :opportunity_stage_changed
    end

    # run/3 calls classifier.classify(artifact, payload, canonical) — a
    # plain map with a :classify fun satisfies the seam. (The behaviour's
    # real use is a named module; see Fixtures.Classifier.)
    defp fn_classifier(decision) when is_function(decision, 3), do: %{classify: decision}

    defp fn_classifier(decision), do: %{classify: fn _a, _p, _c -> decision end}
  end
end
