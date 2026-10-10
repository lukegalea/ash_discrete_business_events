# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Extension do
  @moduledoc """
  The Spark extension whose transformer builds the ledger's
  business-event surface (columns, identity, actions, postgres block
  with the chain and immutability triggers).

  Hosts add it next to the AshEvents extension:

      use Ash.Resource,
        ...,
        extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  It carries no DSL sections of its own — the `:ledger` macro persists
  the declaration's options (`@persist {:bizev_ledger, opts}`) and this
  extension's transformer turns them into the resource, programmatically.
  Programmatic builders, not emitted DSL: the values (table names, SQL,
  module refs) arrive at runtime-of-compilation and quoting them through
  Spark sections would be the wrong tool.
  """

  use Spark.Dsl.Extension,
    transformers: [AshDiscreteBusinessEvents.Ledger.Transformers.DefineLedger]
end
