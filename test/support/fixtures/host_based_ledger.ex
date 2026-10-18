# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.HostBasedLedger do
  @moduledoc """
  A ledger on a host's own base (`Fixtures.HostBase`) whose twin is
  emitted on that base too (`:simulation_base`). It shares the suite's
  ledger tables with `Fixtures.Ledger` (same columns: the base adds a
  change and a policy, not attributes), so it needs no migration of its
  own; its domain is outside `ash_domains`, so codegen never sees it.
  """

  use AshDiscreteBusinessEvents.Fixtures.HostBase,
    domain: AshDiscreteBusinessEvents.Fixtures.HostBaseDomain,
    extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  use AshDiscreteBusinessEvents.Resources,
      {:ledger,
       repo: AshDiscreteBusinessEvents.Test.Repo,
       table: "ledger_events",
       simulation_table: "ledger_simulation_events",
       domain: AshDiscreteBusinessEvents.Fixtures.HostBaseDomain,
       simulation_base:
         {AshDiscreteBusinessEvents.Fixtures.HostBase,
          extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]}}
end
