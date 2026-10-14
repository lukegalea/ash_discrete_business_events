# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.Adapter do
  @moduledoc """
  The adapter boundary behaviour (§1.2) — what a source's `adapter`
  module must implement. Shaped by the first real vertical (§7,
  Salesforce Bulk API 2.0: cursorable state snapshots, PK-chunking,
  daily API budgets) and verified at compile time by
  `AshDiscreteBusinessEvents.Transformers.VerifyAdapters` — a source
  whose adapter does not export every callback fails the host's
  compilation, not the first sync.

  A batch is one sync exchange: the adapter turns a declared stream plus
  a cursor into raw payload maps for the land action, and the next
  cursor. Raw payloads are exactly what the source emitted — byte-for-
  byte fidelity in the JSON sense; interpretation is the mapping's job
  (BIZEV-5), never the adapter's.

  ## The contract

    * `cursor_field/1` — the payload field the stream's cursor tracks
      (Bulk 2.0: `"SystemModstamp"`). The DSL's `cursor :system_modstamp`
      names the STRATEGY; this names the concrete field.
    * `fetch_batch/5` — one sync exchange for the stream: all records
      after `cursor` (a map keyed by the cursor field; `nil` = from the
      beginning), plus the cursor to resume from and whether the stream
      is caught up. Errors raise or return `{:error, term}` — a failed
      batch must be visible, never a silent empty page.
    * `api_calls_per_batch/0` — the adapter's API-call cost for one
      batch (Bulk 2.0: create + poll + retrieve). The sync runner
      accounts calls against the source's `rate_budget` and FAILs the
      job visibly at exhaustion — the feed pauses, it does not degrade.

  ## The boundary's invariants, fixed by design and not up to the adapter

    * Tokens come from the auth edge (`Adapters.AuthProvider`, ADR 0011:
      Nango yields tokens); a connection id is never an action argument.
    * Rows land through BIZEV's land action — ownership, tenancy, region
      admission and lineage attach at land. No staging tables behind the
      boundary.
    * Cursor state is data on SourceRecord/sync-run rows, never job args.
    * Rate budgets are surfaced data; exhaustion is a visible FAIL.
    * Meltano-class tools are workbench taps producing rows the adapter
      can read — never the center, never a second landing path (ADR 0010).
  """

  @type cursor :: map() | nil
  @type batch :: %{
          required(:records) => [map()],
          required(:next_cursor) => cursor(),
          required(:complete?) => boolean()
        }

  @doc "The payload field this stream's cursor tracks (e.g. \"SystemModstamp\")."
  @callback cursor_field(AshDiscreteBusinessEvents.Dsl.Source.Stream.t()) :: String.t()

  @doc """
  One sync exchange for `stream`: every record after `cursor`, the cursor
  to resume from, and whether the stream is caught up.

  `opts`:

    * `:api_calls_used` — calls this run has already spent; the adapter
      accounts its own per-batch cost against the source's budget and
      raises `AshDiscreteBusinessEvents.Adapters.BudgetExhausted` rather
      than silently exceeding it.
    * `:limit` — soft cap on records returned this batch (the adapter may
      return fewer; `complete?` says whether more remain).
  """
  @callback fetch_batch(
              AshDiscreteBusinessEvents.Dsl.Source.t(),
              AshDiscreteBusinessEvents.Dsl.Source.Stream.t(),
              conn :: term(),
              cursor(),
              opts :: keyword()
            ) ::
              {:ok, batch()} | {:error, term()}

  @doc "The API-call cost of one `fetch_batch/5` exchange (budget accounting)."
  @callback api_calls_per_batch() :: pos_integer()
end
