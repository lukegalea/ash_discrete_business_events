# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.CorpusHost do
  @moduledoc """
  The §8 demo-path host: the Salesforce source declared against the REAL
  Bulk 2.0 adapter (the corpus transport doubles the HTTP in tests) and
  the Opportunity mapping — version transitions as the discrete events
  (§7: the raw layer's periods ARE the transitions).

  Declaring the real adapter here also exercises the conformance
  verifier's happy path: `Adapters.SalesforceBulk20` must export every
  callback or this module does not compile.
  """

  use AshDiscreteBusinessEvents, domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

  business_events do
    source :salesforce do
      adapter(AshDiscreteBusinessEvents.Adapters.SalesforceBulk20)
      auth(:nango, provider: "salesforce")
      cursor(:system_modstamp)
      region(:us)
      rate_budget(daily: 250_000)

      stream :opportunity do
        select "SELECT Id, Name, StageName, Amount, CloseDate, SystemModstamp FROM Opportunity"
      end
    end

    mapping :opportunity_stage_changed do
      source {:salesforce, :opportunity}

      map :stage, from: "StageName", type: :string
      map :amount, from: "Amount", type: :integer
      map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec

      constant :source_system, value: "salesforce"

      unmapped_because :close_date, "forecast metadata — not a canonical fact for this kind"
    end
  end
end
