# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SimulationHostBaseTest do
  @moduledoc """
  The twin on the host's base (`:simulation_base`): a host whose ledger
  stands on its own base gets a twin on that base too, so its changes and
  its policies govern simulated events as they govern real ones. Without
  the option the twin stays a bare resource (the rest of the suite).
  """

  use ExUnit.Case, async: false

  alias AshDiscreteBusinessEvents.Fixtures.{HostBase, HostBasedLedger, HostBaseDomain, HostStamp}
  alias AshDiscreteBusinessEvents.Fixtures.HostBasedLedger.SimulationEvent, as: Twin
  alias AshDiscreteBusinessEvents.Fixtures.LedgerEvents
  alias AshDiscreteBusinessEvents.Test.Repo

  describe "the twin's shape" do
    test "carries the base's change, policies and domain, and is still a ledger" do
      assert Ash.Resource.Info.domain(Twin) == HostBaseDomain

      assert Enum.any?(
               Ash.Resource.Info.changes(Twin),
               &match?(%{change: {HostStamp, _}}, &1)
             )

      assert Ash.Policy.Info.policies(Twin) != []

      assert Ash.Resource.Info.action(Twin, :record)
      assert Ash.Resource.Info.attribute(Twin, :simulated)
      assert Ash.Resource.Info.attribute(Twin, :simulation_run).allow_nil? == false
      assert AshPostgres.DataLayer.Info.table(Twin) == "ledger_simulation_events"
    end

    test "a base that does not bring the ledger extensions refuses to compile" do
      quoted =
        quote do
          defmodule AshDiscreteBusinessEvents.SimulationHostBaseTest.Incomplete do
            use HostBase,
              domain: HostBaseDomain,
              extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

            use AshDiscreteBusinessEvents.Resources,
                {:ledger,
                 repo: AshDiscreteBusinessEvents.Test.Repo,
                 table: "ledger_events",
                 simulation_table: "ledger_simulation_events",
                 domain: HostBaseDomain,
                 simulation_base: {HostBase, extensions: [AshEvents.EventLog]}}
          end
        end

      assert_raise ArgumentError,
                   ~r/missing \[AshDiscreteBusinessEvents.Ledger.Extension\]/,
                   fn ->
                     Code.compile_quoted(quoted)
                   end
    end

    test "a simulation_base that is not {module, opts} is refused" do
      quoted =
        quote do
          defmodule AshDiscreteBusinessEvents.SimulationHostBaseTest.Malformed do
            use HostBase,
              domain: HostBaseDomain,
              extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

            use AshDiscreteBusinessEvents.Resources,
                {:ledger,
                 repo: AshDiscreteBusinessEvents.Test.Repo,
                 table: "ledger_events",
                 simulation_table: "ledger_simulation_events",
                 simulation_base: HostBase}
          end
        end

      assert_raise ArgumentError, ~r/simulation_base must be \{module, use_opts\}/, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end

  describe "recording through the host's base" do
    @describetag :db

    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok
    end

    test "the base's change stamps the row and the base's policy governs record" do
      run = "host-base-#{System.unique_integer([:positive])}"

      input =
        [region: :host_base, residency_tag: "host_base"]
        |> LedgerEvents.event()
        |> Map.put(:simulation_run, run)

      # The base's policy: an actor must be present.
      assert {:error, %Ash.Error.Forbidden{}} = Twin.record(input)

      row = Twin.record!(input, authorize?: false)

      assert row.simulated
      assert row.simulation_run == run
      assert row.context["host_base"] == true

      # The real ledger on the same base is stamped the same way, and a sim
      # row never shows up in it.
      real = HostBasedLedger.record!(Map.delete(input, :simulation_run), authorize?: false)
      assert real.context["host_base"] == true

      refute Enum.any?(
               HostBasedLedger.by_region!(:host_base, authorize?: false),
               &(&1.id == row.id)
             )

      # simulation_runs/2 reads through the opts it is given: the base's
      # policy refuses an anonymous authorized read, and the machinery read
      # labels the run.
      assert_raise Ash.Error.Forbidden, fn ->
        AshDiscreteBusinessEvents.simulation_runs(HostBasedLedger, authorize?: true)
      end

      assert %{events: 1, subjects: 1} =
               HostBasedLedger
               |> AshDiscreteBusinessEvents.simulation_runs()
               |> Enum.find(&(&1.simulation_run == run))
    end
  end
end
