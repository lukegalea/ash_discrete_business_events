# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Host do
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

      map :stage, from: "StageName", type: :string
      map :amount, from: "Amount", type: :integer
      map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec

      unmapped_because :owner_email, "PII — kept out of canonical events (§9.5)"
    end
  end
end
