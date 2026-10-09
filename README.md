# AshDiscreteBusinessEvents

<!-- SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events> -->
<!-- SPDX-License-Identifier: MIT -->

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![EPUB render](https://img.shields.io/badge/SPDX-MIT-blue.svg)](REUSE.toml)

The canonical discrete business-event ledger for Ash: external SaaS history
(Salesforce, Stripe, product databases) enters the platform through one typed
boundary — **land → map → ledger** — instead of ad-hoc projectors.

## Executive summary

A first-party public package providing four things as Spark DSL + resource
macros:

1. **SourceRecord** — the raw-landing layer: the raw payload as observed,
   upgraded to *temporal version history* (append-only with change history,
   never upsert-in-place), **stream in the identity** — fixing the E1 known
   gap structurally — zone/region admission checked on the land path
   (refuse-until-tagged), cursor-as-data, and sync-reset as an explicit
   operator action.
2. **The Ledger** — a dedicated `AshEvents.EventLog` (the dedicated-log
   pattern, not the central audit log) whose rows *are* canonical discrete
   business events: who/what/when/why plus `occurred_at` vs `observed_at`,
   a **commit-order `sequence` per region** (per-region advisory-xact-lock
   taken before insert — the audit log's lesson inherited verbatim), a
   **per-region hash chain**, corrections-as-events via `supersedes_event_id`,
   and delivery-level idempotency via `delivery_key`.
3. **Mappings as data** — a versioned, content-hashed mapping DSL (source
   payload → canonical event), optional DMN classification via `ash_decisions`,
   and provenance per rule-application recorded on every ledger row. No
   hard-coded projectors.
4. **The adapter boundary** — Salesforce Bulk API 2.0 first; Nango strictly
   at the auth edge (ADR 0011); Meltano-class tools as workbench, never
   center (ADR 0010).

The ledger is **not** temporal (create-only facts — corrections are new rows,
never rewrites); the raw layer and derived projections **are** (the ADR 0049
mandate, applied precisely). Lineage is emitted at job granularity with an
exported run-id contract; the leak rule is a mechanized acceptance test.
Simulated events get a **separate generated twin resource** — simulated and
real events cannot merge, structurally.

The package ships **resource macros, not concrete modules**: Spark builds
policies at the package's compile time, so concrete modules can't take host
policy blocks — macros inherit the host's grant union natively. Landing
external data is exactly the kind of action a tenant must be able to govern.

## Usage

```elixir
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
```

Resources are instantiated on the host's own base:

```elixir
defmodule MyApp.Platform.SourceRecord do
  use Ash.Resource, domain: MyApp.BusinessEvents, data_layer: AshPostgres.DataLayer
  use AshDiscreteBusinessEvents.Resources, :source_record
end
```

## Status — the slice plan

| Slice | Delivers |
|---|---|
| **BIZEV-2** (this repo) | Design slice: contracts frozen — DSL sections, ledger row shape and SourceRecord identity pinned by fixture tests; review checklist (`docs/REVIEW.md`) |
| BIZEV-3 | SourceRecord: the temporal raw-landing layer |
| BIZEV-4 | The Ledger: dedicated AshEvents log, commit order, hash chains |
| BIZEV-5 | Mapping engine: rules as versioned, content-hashed data |
| BIZEV-6 | Lineage integration (batch granularity, leak-rule test) |
| BIZEV-7 | Salesforce Bulk API 2.0 vertical + fixture corpus |
| BIZEV-8 | Temporal canonical projections over the ledger |
| BIZEV-9 | Corrections & late-arrival semantics |
| BIZEV-10 | Simulation twin (closes SIM-NAMESPACE-ISOLATION) |

Until BIZEV-7's fixture corpus lands, demos run on *internal* event history
and are labeled as such — no demo ever shows external events that did not
traverse the ledger.

## Review discipline

`docs/REVIEW.md` is the checklist every change to this package is reviewed
against. Its first entry rejects hand-rolled validity bookkeeping: any new
`valid_from`/`valid_until` columns on BIZEV resources are a design error —
validity is owned by the temporal extension (raw layer, projections) or
forbidden by mandate (the create-only ledger).

## Installation

```elixir
def deps do
  [
    {:ash_discrete_business_events,
     github: "lukegalea/ash_discrete_business_events"}
  ]
end
```

Requires ash `~> 3.34` and ash_postgres `~> 2.14` (temporal support in tree).
PostgreSQL 18 is the family floor.

## License

MIT — see [LICENSE](LICENSE) and [REUSE.toml](REUSE.toml).
