# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.DslTest do
  @moduledoc """
  The DSL surface freeze: the §1.1 fixture host compiles (that is this
  file loading at all) and `AshDiscreteBusinessEvents.Info` reads the
  declarations back faithfully.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Host
  alias AshDiscreteBusinessEvents.Info

  describe "domains:" do
    test "the persisted domains opt is read back" do
      assert Info.domains(Host) == [AshDiscreteBusinessEvents.Fixtures.Domain]
    end
  end

  describe "sources" do
    test "the fixture's source is declared with its schema-verified options" do
      source = Info.source(Host, :salesforce)

      assert %AshDiscreteBusinessEvents.Dsl.Source{} = source
      assert source.name == :salesforce
      assert source.adapter == AshDiscreteBusinessEvents.Fixtures.StubAdapter
      assert source.cursor == :system_modstamp
      assert source.region == :us
      assert source.rate_budget == [daily: 250_000]
    end

    test "unknown source names return nil" do
      assert Info.source(Host, :stripe) == nil
    end

    test "the nested auth declaration round-trips" do
      auth = Info.auth(Host, :salesforce)

      assert %AshDiscreteBusinessEvents.Dsl.Source.Auth{} = auth
      assert auth.strategy == :nango
      assert auth.provider == "salesforce"
    end

    test "the nested stream declaration round-trips" do
      stream = Info.stream(Host, :salesforce, :opportunity)

      assert %AshDiscreteBusinessEvents.Dsl.Source.Stream{} = stream
      assert stream.name == :opportunity

      assert stream.select ==
               "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
    end

    test "stream_of finds by name on the source struct" do
      source = Info.source(Host, :salesforce)
      assert Info.stream_of(source, :opportunity).name == :opportunity
      assert Info.stream_of(source, :lead) == nil
    end

    test "stream/auth lookups on unknown sources return nil" do
      assert Info.stream(Host, :stripe, :charge) == nil
      assert Info.auth(Host, :stripe) == nil
    end
  end

  describe "mappings" do
    test "the fixture's mapping is declared with its source tuple" do
      mapping = Info.mapping(Host, :opportunity_stage_changed)

      assert %AshDiscreteBusinessEvents.Dsl.Mapping{} = mapping
      assert mapping.name == :opportunity_stage_changed
      assert Info.mapping_source(mapping) == {:salesforce, :opportunity}

      # BIZEV-5: the closed operator vocabulary lands in declaration order,
      # and the transformer compiles the content hash onto the entity.
      assert Enum.map(mapping.ops, & &1.op) == [:map, :map, :map, :unmapped_because]
      assert Enum.map(mapping.ops, & &1.target) == [:stage, :amount, :occurred_at, :owner_email]
      assert byte_size(mapping.hash) == 8
      assert mapping.artifact["ops"] |> length() == 4

      # The artifact's ops preserve DECLARATION order (ora-3 §13.3) —
      # the hash's input.
      assert Enum.map(mapping.artifact["ops"], & &1["target"]) ==
               ["stage", "amount", "occurred_at", "owner_email"]
    end

    test "unknown mapping names return nil" do
      assert Info.mapping(Host, :opportunity_created) == nil
    end

    test "mappings and sources enumerate in declaration order" do
      assert Enum.map(Info.mappings(Host), & &1.name) == [:opportunity_stage_changed]
      assert Enum.map(Info.sources(Host), & &1.name) == [:salesforce]
    end
  end

  describe "mapping declaration forms" do
    test "the blockless keyword form declares source" do
      defmodule Host.KeywordMapping do
        use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

        business_events do
          source :salesforce do
            region :us
            stream :opportunity
          end

          mapping(:opportunity_stage_changed, source: {:salesforce, :opportunity})
        end
      end

      mapping = Info.mapping(Host.KeywordMapping, :opportunity_stage_changed)
      assert Info.mapping_source(mapping) == {:salesforce, :opportunity}
    end

    test "a keyword option before a do-block is unrepresentable (Elixir grammar)" do
      # The design §1.1 example writes
      #   mapping :name, source: {...} do ... end
      # but Elixir parses a keyword list before a do-block as a THIRD
      # macro argument, which Spark entity macros (args…, opts) cannot
      # receive. The frozen surface is the block form (fixture Host) and
      # the blockless keyword form (above). Flagged for ora-3 review.
      error =
        catch_error(
          defmodule Host.KeywordAndBlock do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              mapping :opportunity_stage_changed, source: {:salesforce, :opportunity} do
                # operator placeholder
              end
            end
          end
        )

      assert %CompileError{} = error
    end
  end

  describe "schema verification" do
    test "an unknown option in keyword form is a DslError, not a silent ignore" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.BadOptionKeyword do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source(:bad,
                adapter: AshDiscreteBusinessEvents.Fixtures.StubAdapter,
                region: :us,
                not_an_option: :nope
              )
            end
          end
        end

      assert error.message =~ "not_an_option"
    end

    test "an unknown option in block form is a compile error, not a silent ignore" do
      # Inside a block, an unrecognized option name has no generated macro
      # to call — Elixir rejects the module at compile time. Same guarantee
      # (a typo fails loudly), different error shape.
      error =
        assert_raise CompileError, fn ->
          defmodule Host.BadOptionBlock do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :bad do
                adapter(AshDiscreteBusinessEvents.Fixtures.StubAdapter)
                region(:us)
                not_an_option(:nope)
              end
            end
          end
        end

      assert %CompileError{} = error
    end

    test "a source without region is rejected — region is required, first-class (§6)" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.NoRegion do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              source :bad do
                adapter(AshDiscreteBusinessEvents.Fixtures.StubAdapter)
              end
            end
          end
        end

      assert error.message =~ "region"
    end

    test "the adapter option is a module reference, schema-verified as such" do
      # Spark's {:behaviour, _} type verifies option *shape* (a module
      # atom) — compliance with the boundary behaviour is BIZEV-7's first
      # verifier, together with the callbacks themselves. The fixture
      # round-trip pins that the option carries the module faithfully.
      source = Info.source(Host, :salesforce)
      assert source.adapter == AshDiscreteBusinessEvents.Fixtures.StubAdapter
    end

    test "a mapping whose source is not a {source, stream} tuple is rejected" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          defmodule Host.BadTuple do
            use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

            business_events do
              mapping(:bad, source: :salesforce)
            end
          end
        end

      assert error.message =~ "source"
    end

    test "an unknown use-opt is rejected at the boundary" do
      error =
        assert_raise Spark.Options.ValidationError, fn ->
          defmodule Host.BadUseOpt do
            use AshDiscreteBusinessEvents, domians: [AshDiscreteBusinessEvents.Fixtures.Domain]
          end
        end

      assert Exception.message(error) =~ "domians"
    end
  end
end
