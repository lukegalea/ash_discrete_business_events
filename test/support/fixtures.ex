# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures do
  @moduledoc """
  Compile-time fixtures for the BIZEV-2 shape-freeze tests.

  The fixture host declares the design §1.1 example source + mapping so
  the DSL surface is exercised *by the compiler*, and the fixture adapter
  satisfies the (callback-less) adapter boundary behaviour. The row-shape
  contracts themselves live as module attributes inside the contract test
  files — these are what BIZEV-3/4 must satisfy.
  """

  defmodule StubAdapter do
    @moduledoc """
    A stand-in adapter module for the fixture source.

    A plain module, deliberately: the boundary behaviour has no callbacks
    until BIZEV-7 shapes them, and a zero-callback module cannot be
    `@behaviour`-adopted without a compiler warning. When the callbacks
    land, this becomes `@behaviour`-compliant and the schema's
    `{:behaviour, ...}` documentation becomes enforced verification.
    """
  end

  defmodule Host do
    @moduledoc """
    The §1.1 fixture host: declares a Salesforce source (auth, cursor,
    region, rate budget, one stream) and one mapping for it.
    """

    use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

    business_events do
      source :salesforce do
        adapter(AshDiscreteBusinessEvents.Fixtures.StubAdapter)
        auth(:nango, provider: "salesforce")
        cursor(:system_modstamp)
        region(:us)
        rate_budget(daily: 250_000)

        stream :opportunity do
          select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
        end
      end

      # The design §1.1 writes `mapping :name, source: {...} do ... end`;
      # Elixir parses a keyword list before a do-block as a THIRD macro
      # argument, which Spark entity macros (args…, opts) cannot receive —
      # so the frozen surface is the block form below (Ash's convention),
      # with the keyword form kept working for blockless declarations.
      # Flagged for ora-3 review; see dsl_test.exs, which pins both forms.
      mapping :opportunity_stage_changed do
        source {:salesforce, :opportunity}
        # closed operator vocabulary — BIZEV-5
      end
    end
  end
end
