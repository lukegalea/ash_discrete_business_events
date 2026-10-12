# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Ledger do
  @moduledoc """
  The macro-generated ledger on the suite's own base — the same posture
  a host takes. The host declares the base (domain, data layer,
  authorizer, the AshEvents extension) and the `:ledger` options; the
  macro emits the ledger body AND the simulation twin
  (`AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent`).
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  use AshDiscreteBusinessEvents.Resources,
      {:ledger,
       repo: AshDiscreteBusinessEvents.Test.Repo,
       table: "ledger_events",
       simulation_table: "ledger_simulation_events",
       domain: AshDiscreteBusinessEvents.Fixtures.Domain,
       clear_records_for_replay: AshDiscreteBusinessEvents.Fixtures.LedgerClearForReplay}

  # The macro-not-concrete-module posture, proven again at the ledger:
  # the HOST's policy block governs record / the region-scoped reads /
  # cross_region_read natively (ADR 0035's reversal clause). Permissive
  # in the fixture; a real tenant gates the alarmed cross-region door.
  #
  # The one refusal is on the internal `:append`: an actor flagged
  # `blocked?` may call `record` but not reach the insert. It exists to
  # prove `record` hands its caller's actor (and `authorize?`) to the
  # append — see the "caller context" tests.
  policies do
    policy action(:append) do
      forbid_if actor_attribute_equals(:blocked?, true)
      authorize_if always()
    end

    policy always() do
      authorize_if always()
    end
  end
end
