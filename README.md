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
| **BIZEV-2** | Contracts frozen — DSL sections, ledger row shape and SourceRecord identity pinned by fixture tests; review checklist (`docs/REVIEW.md`) |
| **BIZEV-3** | SourceRecord: the temporal raw-landing layer |
| **BIZEV-4** (this branch) | **The Ledger: the dedicated AshEvents log — locked, chained, append-only** |
| BIZEV-5 | Mapping engine: rules as versioned, content-hashed data |
| BIZEV-6 | Lineage integration (batch granularity, leak-rule test) |
| BIZEV-7 | Salesforce Bulk API 2.0 vertical + fixture corpus |
| BIZEV-8 | Temporal canonical projections over the ledger |
| BIZEV-9 | Corrections & late-arrival semantics |
| BIZEV-10 | Simulation twin (closes SIM-NAMESPACE-ISOLATION) |

Until BIZEV-7's fixture corpus lands, demos run on *internal* event history
and are labeled as such — no demo ever shows external events that did not
traverse the ledger.

## The ledger (BIZEV-4)

A dedicated `AshEvents.EventLog` whose rows *are* canonical discrete
business events (design §1.4, §5.1) — plus its **simulation twin** from the
same declaration (§5.6, SIM-NAMESPACE-ISOLATION: two modules, two tables;
sim rows carry `simulated: true` and a `simulation_run` label, and can
never reach a real projector's rebuild because the real rebuild reads the
real module's table):

```elixir
defmodule MyApp.Platform.Ledger do
  use Ash.Resource,
    domain: MyApp.BusinessEvents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  use AshDiscreteBusinessEvents.Resources, {:ledger,
    repo: MyApp.Repo,
    table: "ledger_events",
    simulation_table: "ledger_simulation_events",
    domain: MyApp.BusinessEvents}

  policies do
    # your grants govern record / the region-scoped reads / the alarmed
    # cross_region_read natively
  end
end
```

The row is the §1.4 table, concrete: `action` rides the event kind
(projector-dispatchable as-is) with `data` the canonical payload; the
subject and actor ride as **descriptors, never foreign keys**;
`occurred_at` (source truth) / `observed_at` (when we learned) /
`sequence` (commit order) are three clocks answering three questions;
`context` + `provenance` (mapping name, version hash, source record);
`supersedes_event_id` — corrections are new rows, never rewrites;
`delivery_key` — webhook idempotency below source idempotency; `region` +
`residency_tag`.

The machinery, owned here:

- **Commit order**: the `record` path takes a per-region advisory
  xact lock **before** insert (`RegionLockKeyGenerator`), so the
  bigserial `sequence` is assigned only after the previous same-region
  writer committed — *within one region, sequence order is commit order*.
  A plain bigserial without the lock is the canonical wrong thing to
  build a feed on; the three caveats are documented on the generator and
  pinned by a permanent concurrent-writers test.
- **Tamper evidence**: per-region SHA-256 hash chains, written by a
  `BEFORE INSERT` trigger and verified in SQL with the same expression:

  ```sh
  mix bizev.verify_chains --resource MyApp.Ledger [--region us] [--json]
  ```

- **Append-only**: update/destroy actions do not exist, AshEvents' stock
  create is removed, and the emitted immutability trigger refuses UPDATE
  and DELETE at the database. Correct a wrong entry by recording a new
  one.
- **Region discipline (§6)**: consumer reads (`by_region`, `feed`,
  `by_subject`, `by_id`) all require a region; `feed` is the
  high-watermark commit-order feed. The one gated exception,
  `cross_region_read`, needs two or more explicit regions and records a
  `:"region.disclosure"` row **in each queried region's chain** — a
  cross-region total is shown with its jurisdictions, never without.

```elixir
MyApp.Platform.Ledger.record!(%{
  event_kind: :"opportunity.stage_changed",
  region: :us,
  residency_tag: "us",
  subject_type: "crm.opportunity",
  subject_external_id: "0065f000003Xy7ZAAS",
  occurred_at: occurred_at,
  provenance: %{mapping_name: "...", mapping_version_hash: "...", source_record_id: "..."},
  data: payload
})

# The commit-order feed for a consumer's cursor:
MyApp.Platform.Ledger.feed!(:us, %{after_sequence: last_seen_sequence})
```

## The raw layer (BIZEV-3)

Instantiate the SourceRecord on your own base — the resource macro, not a
concrete module, so your policies govern the land and read actions natively:

```elixir
defmodule MyApp.Ingestion.SourceRecord do
  use Ash.Resource,
    domain: MyApp.BusinessEvents,
    data_layer: AshPostgres.DataLayer

  use AshDiscreteBusinessEvents.Resources, :source_record

  postgres do
    table "source_records"
    repo MyApp.Repo
  end
end
```

The macro emits the temporal raw layer (design §1.3):

- **One record per `(source, stream, external_id, region)` identity**, with
  version history as periods: `valid_at = [fetched_at, next observation)`.
  The identity is period-aware `WITHOUT OVERLAPS` (a GiST exclusion
  constraint) — **stream and region live in the identity**, structurally
  fixing the two-streams-one-id collision. There are NO hand-rolled
  `valid_from`/`valid_until` columns; the temporal extension owns validity.
- **`land` is idempotent at the source layer**: identical content (same
  payload and cursor) is a temporal no-op; changed content splits the
  period at the observation instant — history is never overwritten. The
  decision is made against the version valid *at `fetched_at`*, so a
  late-arriving duplicate of already-observed content is a no-op, not a
  new period.
- **Zone/residency admission at land**: the land action refuses until the
  observation is tagged, and refuses a tag that does not admit into the
  target region (ADR 0042: admission is checked where data is first
  written, never at egress).
- **Cursor-as-data**: `cursor` and `fetched_at` ride the observation;
  `advance_cursor` and `reset_cursor` are explicit actions whose changes
  are splits — cursor history is observation history, never a rewrite.
  Re-sync after reset can neither duplicate (identical content is a no-op)
  nor silently revise (changed content opens a visible new period).
- **As-of reads**: `SourceRecord.at(source, stream, external_id, region,
  as_of)` answers *what did the source say at T* as an index-backed
  containment read, not a replay.

```elixir
{:ok, landed} =
  MyApp.Ingestion.SourceRecord.land(%{
    source: :salesforce,
    stream: :opportunity,
    external_id: "0065f000003Xy7ZAAS",
    region: :us,
    residency_tag: "us",
    raw_payload: payload,
    cursor: %{"system_modstamp" => "2026-10-01T14:09:30.000+0000"},
    fetched_at: fetched_at
  })

# What did the source say on Oct 1?
MyApp.Ingestion.SourceRecord.at(:salesforce, :opportunity, "0065f000003Xy7ZAAS",
  :us, ~U[2026-10-01 16:00:00.000000Z]
)
```

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
