# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.Adapter do
  @moduledoc """
  The adapter boundary behaviour — what a source's `adapter` module must
  implement.

  BIZEV-2 declares the boundary and pins it in the source schema
  (`adapter` is `{:behaviour, __MODULE__}`); the callbacks themselves
  land with the first real adapter (BIZEV-7, Salesforce Bulk API 2.0 —
  with the `SystemModstamp` cursor, PK-chunking and daily-budget realities
  of design §7). Defining callbacks now would invent a contract the
  vertical hasn't shaped yet.


  The boundary's invariants, fixed by design and not up to the adapter:

    * The adapter reads tokens through the auth edge (ADR 0011); a
      connection id is never an action argument.
    * The adapter lands rows through BIZEV's land action — an ordinary
      Ash action where ownership, tenancy, region admission and lineage
      attach. It never writes staging tables behind the boundary.
    * Cursor state is data on SourceRecord/sync-run rows, never job args.
    * Rate budgets are surfaced data: exhaustion is a visible FAIL (the
      feed pauses, it does not degrade).
    * Meltano-class tools are workbench taps producing rows the adapter
      can read — never the center, never a second landing path (ADR 0010).
  """

  # TODO(BIZEV-7): the callbacks, shaped by the Salesforce Bulk API 2.0
  # vertical: sync (cursorable state snapshots → version transitions),
  # webhook receipt (delivery-keyed), backfill via workbench taps. Until
  # then this module carries the boundary's invariants and nothing else —
  # a zero-callback module cannot be `@behaviour`-adopted without a
  # compiler warning, so adapters do not adopt it yet, and the source
  # schema's `{:behaviour, ...}` type documents the contract (Spark
  # verifies option *shape*; compliance verification is BIZEV-7's first
  # verifier, together with the callbacks).
end
