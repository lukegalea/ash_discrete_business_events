# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents do
  @moduledoc """
  The canonical discrete business-event ledger for Ash.

  External SaaS history (Salesforce, Stripe, product databases) enters the
  platform through one typed boundary, in three layers:

    * **SourceRecord** — the raw-landing layer: the raw payload as observed,
      immutable, with *temporal version history* (append-only periods keyed
      by `(source, stream, external_id, region)`), cursor-as-data, and
      zone/residency admission checked on the land path.
    * **The Ledger** — a dedicated, append-only `AshEvents.EventLog` whose
      rows *are* canonical discrete business events: who/what/when/why,
      `occurred_at` vs `observed_at`, a commit-order `sequence` per region
      (advisory-xact-lock), a per-region hash chain, corrections-as-events
      via `supersedes_event_id`, and delivery-level idempotency.
    * **Mappings as data** — versioned, content-hashed declarations that
      turn a raw observation into a canonical event, recording provenance
      on every ledger row.

  The ledger is **not** temporal (create-only facts — corrections are new
  rows, never rewrites); the raw layer and host projections **are**. See
  the README for the full design summary and `docs/REVIEW.md` for the
  review checklist that guards these rulings.

  ## Usage

      defmodule MyApp.BusinessEvents do
        use AshDiscreteBusinessEvents, domains: [MyApp.BusinessEvents]

        business_events do
          source :salesforce do
            adapter MyApp.Adapters.SalesforceBulk20
            auth :nango, provider: "salesforce"
            cursor :system_modstamp
            region :us
            rate_budget [daily: 250_000]

            stream :opportunity do
              select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
            end
          end

          mapping :opportunity_stage_changed, source: {:salesforce, :opportunity} do
            # closed operator vocabulary — lands in BIZEV-5
          end
        end
      end

  Hosts instantiate the resources on their own base via the resource
  macros — `use AshDiscreteBusinessEvents.Resources, :source_record` and
  `:ledger` — **resource macros, not concrete modules**: Spark builds
  policies at the package's compile time, so concrete modules can't take
  host policy blocks; macros inherit the host's grant union natively.
  Landing external data is exactly the kind of action a tenant must be
  able to govern.

  ## Status

  BIZEV-2 (this slice) freezes the contracts: the DSL surface, the ledger
  row shape and the SourceRecord identity tuple are pinned by
  fixture-pinned contract tests. The resources themselves land in
  BIZEV-3 (SourceRecord) and BIZEV-4 (the ledger); the mapping operators
  in BIZEV-5.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [AshDiscreteBusinessEvents.Extension]],
    opt_schema: [
      domains: [
        type: {:list, :atom},
        doc:
          "The host Ash domains this declaration serves. Recorded as data on the " <>
            "host module (read it back with `AshDiscreteBusinessEvents.Info.domains/1`); " <>
            "later slices use it for wiring and verification (the ledger macro binds " <>
            "generated resources to these domains)."
      ]
    ]

  # Runs in the host module when it declares `use AshDiscreteBusinessEvents`.
  # Spark validates the `use` options against `opt_schema` above before this
  # runs; we persist the accepted ones so `AshDiscreteBusinessEvents.Info`
  # can read them back (the `otp_app` pattern from `Spark.Dsl`).
  @doc false
  def handle_opts(opts) do
    domains = opts |> Keyword.get(:domains, []) |> Macro.escape()

    quote do
      @persist {:domains, unquote(domains)}
    end
  end
end
