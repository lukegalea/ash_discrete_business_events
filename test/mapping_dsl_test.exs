# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingDslTest do
  @moduledoc """
  The mapping engine's compile-time refusals: the closed operator
  vocabulary is schema-verified (a typo is an error, each shape accepts
  only its own options), redundancy is refused BY NAME, the footguns are
  refused, the occurred-vs-observed discipline is compiler-enforced, and
  a mapping wired to an undeclared source/stream fails compilation.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Info

  defmodule Classified do
    @moduledoc "A classifier implementation for the classify_with round-trip pin."
    @behaviour AshDiscreteBusinessEvents.Mappings.Classifier

    @impl true
    def classify(_artifact, _payload, _canonical), do: :emit
  end

  describe "the closed vocabulary is schema-verified" do
    test "an unknown operator is a compile error, not a silent ignore" do
      error =
        assert_raise CompileError, fn ->
          defmodule Host.UnknownOp do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :stage, from: "StageName", type: :string
                map :occurred_at, from: "T", type: :utc_datetime_usec

                project :stage, onto: "somewhere"
              end
            end
          end
        end

      assert error.message =~ "project"
    end

    test "an operator option outside its own shape is refused (map has no separator)" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.CrossShape do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :stage, from: "StageName", separator: "-"
                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "separator"
    end

    test "a nil constant value is refused — that is unmapped_because's job" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.NilConstant do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                constant :hole, value: nil
                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "value"
    end

    test "decode without cases is refused at the schema" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.DecodeNoCases do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                decode :stage_bucket, from: "StageName"
                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "cases"
    end
  end

  describe "redundancy refused by name, at compile time" do
    test "two operators writing the same target key fail, each named with its position" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.DuplicateTarget do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :stage, from: "StageName", type: :string
                decode :stage, from: "Stage", cases: %{"A" => "a"}
                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "target `stage` is written by map (op 1), decode (op 2)"
    end
  end

  describe "the occurred-vs-observed discipline is compiler-enforced" do
    test "a mapping without an occurred_at extraction fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.NoOccurredAt do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :stage, from: "StageName", type: :string
              end
            end
          end
        end

      assert error.message =~ "no occurred_at extraction"
    end

    test "an occurred_at extraction with a non-datetime type fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.StringOccurredAt do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :occurred_at, from: "T", type: :string
              end
            end
          end
        end

      assert error.message =~ "occurred_at extraction must have a datetime type"
    end

    test "occurred_at declared unmapped fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.UnmappedOccurredAt do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :occurred_at, from: "T", type: :utc_datetime_usec

                unmapped_because :occurred_at, "nobody needs it, surely"
              end
            end
          end
        end

      assert error.message =~ "occurred_at cannot be declared unmapped"
    end

    test "footguns fail compilation: an empty coalesce" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.EmptyCoalesce do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :t}

                map :occurred_at, from: "T", type: :utc_datetime_usec
                coalesce :close_date, from: []
              end
            end
          end
        end

      assert error.message =~ "coalesce on `close_date` has no paths"
    end
  end

  describe "the source tuple is compiler-verified" do
    test "an undeclared source fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.UndeclaredSource do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:stripe, :charges}

                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "not a declared source"
      assert error.message =~ ":stripe"
    end

    test "an undeclared stream on a declared source fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.UndeclaredStream do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :s do
                region :us
                stream :t
              end

              mapping :bad do
                source {:s, :accounts}

                map :occurred_at, from: "T", type: :utc_datetime_usec
              end
            end
          end
        end

      assert error.message =~ "not declared on source"
      assert error.message =~ ":accounts"
    end
  end

  describe "the classify_with seam" do
    test "round-trips onto the mapping entity and onto the artifact" do
      defmodule Host.Classified do
        use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

        business_events do
          source :s do
            region :us
            stream :t
          end

          mapping :classified_event do
            source {:s, :t}
            classify_with AshDiscreteBusinessEvents.MappingDslTest.Classified

            map :occurred_at, from: "T", type: :utc_datetime_usec
          end
        end
      end

      mapping = Info.mapping(Host.Classified, :classified_event)
      assert mapping.classify_with == AshDiscreteBusinessEvents.MappingDslTest.Classified

      artifact = AshDiscreteBusinessEvents.Mappings.Compiler.artifact(mapping)

      assert artifact["classify_with"] ==
               "Elixir.AshDiscreteBusinessEvents.MappingDslTest.Classified"
    end
  end
end
