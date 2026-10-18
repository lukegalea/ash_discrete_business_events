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
      map :stage, from: "StageName", type: :string
      map :amount, from: "Amount", type: :integer
      map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec

      constant :source_system, value: "salesforce"

      unmapped_because :owner_email, "PII — kept out of canonical events"
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
| **BIZEV-4** | The Ledger: the dedicated AshEvents log — locked, chained, append-only |
| **BIZEV-5** | The mapping engine: rules as versioned, content-hashed data |
| **BIZEV-6** | Lineage integration: the run-id contract, batch-granular emission, the leak rule |
| **BIZEV-7** | Salesforce Bulk API 2.0 vertical + the fixture corpus (the honest demo input) |
| **BIZEV-8** | Temporal canonical projections over the ledger, with a package-owned region-scoped drain |
| **BIZEV-9** | Corrections & late-arrival semantics |
| **BIZEV-10** | Simulation twin (closes SIM-NAMESPACE-ISOLATION) |
| **BIZEV-12** | Retention & GDPR: partitioned raw layer, audited purge, erasure-as-event, PII lint |
| **BIZEV-13** | The BPMN trigger bridge: nudge-on-append + sweep, `process_ref` |

All of the slices above are on `main`. Demos follow [the honest demo
path](#the-honest-demo-path-8): external history shown in a demo comes from
the fixture corpus through the ledger, never from anywhere else.

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

## The mapping engine (BIZEV-5)

A `mapping` declares one event kind's rule for turning a SourceRecord
observation into canonical event fields. The body's vocabulary is
**closed and schema-verified** — a typo is a compile error, and each
operator accepts only its own options:

- `map :target, from: "Path", type: :atom` — payload path → target key,
  cast to the Ash type; an absent path writes nothing (no silent nils).
- `decode :target, from: "Path", cases: %{"source" => "canonical"}`
  (optional `default:`) — a translation table. A present value with no
  case is a **loud apply-time error**; routing surprises must not fold
  silently.
- `coalesce :target, from: ["A", "B"]` — the first non-nil value, in
  priority order.
- `concat :target, from: ["A", "B"], separator: " / "` — the non-nil
  parts joined.
- `constant :target, value: "fixed"` — a fixed JSON-term value.
- `unmapped_because :target, "why"` — refusal by name: a deliberately
  unmapped key and its reason are authored data carried on the artifact
  and surfaced on every apply, never a silent absence.

The compiler refuses redundancy **by name** (two operators writing the
same target key fail compilation, each named with its operator and
declaration position) and the known footguns (empty path/case lists, a
nil `constant`). It also enforces the **occurred-vs-observed discipline**
(§1.3): every mapping must extract `occurred_at` — the source's truth
time — from the payload with a datetime type. The mapping owns no clock;
observed time is the write's business.

### Rules as data

Each declaration compiles to a canonical artifact and a content hash (8
hex chars of the artifact's SHA-256). **The hash covers the operators in
declaration order** (§13.3): the ops are serialized as a *list* — never
Map iteration — so reordering the rules is a different rule, with a
different hash. The name is part of the hash on purpose: the mapping
name *is* the event kind the rule emits, so a rename mints a new
version rather than masquerading as the same rule.

The artifact is published into a `MappingVersion` resource — the same
snapshot lifecycle as ash_decisions: **draft → validate → activate**.
`validate` re-runs the compiler's structural checks over the *stored*
artifact (a drifted or hand-edited row is refused loudly);
`activate` freezes the version as the name's active one, superseding —
demoting, never rewriting — the previous active. Content never changes
after draft: a changed declaration mints a new version row.

```elixir
defmodule MyApp.Platform.MappingVersion do
  use Ash.Resource, domain: MyApp.BusinessEvents, data_layer: AshPostgres.DataLayer

  use AshDiscreteBusinessEvents.Resources, :mapping_version

  postgres do
    table "mapping_versions"
    repo MyApp.Repo
  end
end

# Publish the declared rule, walk the lifecycle:
{:ok, version} =
  AshDiscreteBusinessEvents.Mappings.publish(
    MyApp.BusinessEvents,
    :opportunity_stage_changed,
    MyApp.Platform.MappingVersion
  )

version
|> MyApp.Platform.MappingVersion.validate_version!()
|> AshDiscreteBusinessEvents.Mappings.activate!()

# The name's active version — what new applies use:
AshDiscreteBusinessEvents.Mappings.active_version(
  MyApp.Platform.MappingVersion,
  :opportunity_stage_changed
)
```

### The apply path

`AshDiscreteBusinessEvents.Mappings.run/3` applies an artifact (or a
stored version) to a raw payload. It is a **pure function** — no clocks,
no actors, no I/O — so rule-version-pinned replay is a property of the
engine, not a discipline of its callers: the same artifact over the same
payload yields the same canonical fields, always.

```elixir
{:ok, canonical} =
  AshDiscreteBusinessEvents.Mappings.run(active_version, source_record.raw_payload,
    source_record_id: source_record.id
  )

canonical.event_kind   # the mapping name — unless a classifier overrode it
canonical.occurred_at  # the source's truth time, from the payload
canonical.data         # the written targets (occurred_at excluded — it has its own ledger column)
canonical.unmapped     # the unmapped_because refusals, by name
canonical.provenance   # %{mapping_name, mapping_version_hash, source_record_id}
```

`canonical.provenance` is the ledger row's join, ready-made: the
`mapping_name` + `mapping_version_hash` pair resolves to exactly one
`MappingVersion` row, so any ledger row points back into replayable data
rather than a code revision. Re-applying vN reproduces vN's outputs
byte-for-byte; activating vN+1 changes the outputs only where its
operators differ.

### Classification is a seam, not a dependency

*Which records become which event kind* — routing, thresholds — is not
the operators' job (they shape the event) and not this package's job. A
mapping may name a module implementing the
`AshDiscreteBusinessEvents.Mappings.Classifier` behaviour
(`classify_with`); it returns `:emit`, `{:emit, kind}`, `{:skip,
reason}`, or `{:error, term}`. An ash_decisions DMN table behind this
behaviour is the host's wiring — the package ships the seam and the
behaviour, never the dependency.

## Lineage (BIZEV-6)

Lineage maps the graph of *what moved* — never who moved it or for whom.
The package exports the contract (`AshDiscreteBusinessEvents.Lineage`) so
host-emitted STARTs and package-emitted COMPLETEs share the vocabulary by
construction, and `AshDiscreteBusinessEvents.RunContext` so fan-outs
inherit parent threading instead of re-deriving it.

**Emission is batch-granular and template-owned** (design §3.1): the unit
of data movement is the sync run (or webhook batch), not the row — N landed
rows are ONE job. `Lineage.run/3` is the job template, ready-made: START
before the batch, COMPLETE after, FAIL loudly on a raise/throw/exit
(re-raised). The AshOpenLineage notifier is registered on NO BIZEV
resource — high-volume machine rows would turn per-row COMPLETEs into
noise (test-pinned, including "landing N rows emits zero events").

**The structural naming vocabulary** (§3.2) — fixed here, shared everywhere:

| Thing | Name |
|---|---|
| sync job | `bizev.sync.<source>.<stream>` |
| webhook job | `bizev.webhook.<source>` |
| replay job | `bizev.replay.<projection>` |
| raw dataset | `bizev.raw.<source>.<stream>` |
| ledger dataset | `bizev.ledger.<region>` — per-region; a cross-region total is never one dataset |
| mapping-rule version | `bizev.rules.<mapping>.v<hash8>` — a mapping version is an INPUT dataset |

Stream ranges appear only as facet-level **counts** (`:counts` on
`emit_complete/3`), never boundary values. The leak rule is an acceptance
test with a bites-proof: actor, tenant, customer and filter-value strings
are injected into every channel the API accepts and asserted absent from
the emitted events — after the checker is proven to fail on a
deliberately-leaking map first.

**Run identity is split by what the run must join to** (§3.3):

- *Operational* runs (sync, webhook, corrections, resets) are
  **correlation-derived** — `Lineage.run_id(:operational)` is the host
  `CorrelationProvider`'s id: one lookup joins the audit log.
- *Derivation* runs (replays, re-mapping backfills) are
  **content-derived** — `Lineage.run_id(%{purpose:, ledger_range:,
  mapping_versions:})` hashes the inputs into a deterministic UUID, so an
  identical replay maps to the SAME run instead of minting a look-alike.
  Lineage carries the derivation edge; the audit log carries the
  operation.

```elixir
job = AshDiscreteBusinessEvents.Lineage.job(:sync,
  source: :salesforce, stream: :opportunity)

run_id = AshDiscreteBusinessEvents.Lineage.run_id(:operational)

AshDiscreteBusinessEvents.Lineage.run(job, run_id, fn ->
  # the batch: land N rows, advance the cursor — one job, one run
  :ok
end)

# …or with facet-level counts on the outputs:
AshDiscreteBusinessEvents.Lineage.emit_complete(job, run_id,
  counts: %{"bizev.raw.salesforce.opportunity" => 42}
)
```

**Fan-out parent propagation** (§3.4) — the process dictionary does not
cross process boundaries, so the parent identity travels as data:

```elixir
# the job template puts the parent into Oban args as a STRING key
# (atom keys miss silently after the JSON round-trip):
args = AshDiscreteBusinessEvents.RunContext.put_parent(args, parent_run_id)

# worker entry re-establishes the scope (host correlation wiring is a
# {module, function} of arity 2 — Correlation.with_correlation/2's shape —
# under config :ash_discrete_business_events, :scope_establisher):
AshDiscreteBusinessEvents.RunContext.enter_from_args(args, fn ->
  # the batch — Lineage.parent_opts/0 now resolves the parent facet
end)

# Task fan-outs pass the parent explicitly — spawn does not inherit scope:
AshDiscreteBusinessEvents.RunContext.fan_out(items, fn item -> ... end)
```

A nested run (depth > 0 per the correlation provider) whose parent id
resolves emits the `parent` run facet; omitted, never fabricated,
otherwise.

## The Salesforce vertical (BIZEV-7)

The adapter boundary is real and **compile-time verified** (§13.2): a
source's `adapter` must export every `Adapters.Adapter` callback —
`cursor_field/1`, `fetch_batch/5`, `api_calls_per_batch/0` — or the host
does not compile; a source declaring more than one `auth` edge is
rejected outright (ADR 0011).

**`Adapters.SalesforceBulk20`** implements the vertical (§7): one query
job per sync — `WHERE SystemModstamp > <cursor> ORDER BY
SystemModstamp` — polled to completion, results downloaded (PK-chunked
result sets fetched whole, each chunk an accounted API call), the next
cursor = the results' max `SystemModstamp`. **Budgets are data**: every
transport call is accounted against the source's `rate_budget`;
exhaustion raises `Adapters.BudgetExhausted` inside the job — the job FAILs
visibly, lineage records it, `Sync.run/1` returns
`{:error, %Adapters.BudgetExhausted{landed:, cursor:}}`, and the feed PAUSES
at the last completed batch's cursor (never degrades). Tokens come from the configured
`Adapters.AuthProvider` (ADR 0011: Nango yields tokens; a connection id
is never an action argument; the HTTP seam is a behaviour — CI runs the
adapter against the fixture-corpus transport, never a live org).

```elixir
# the sync job template (the host's Oban job calls this):
{:ok, summary} =
  AshDiscreteBusinessEvents.Adapters.Sync.run(
    source: Info.source(MyApp.BusinessEvents, :salesforce),
    stream: Info.stream_of(source, :opportunity),
    source_record: MyApp.Platform.SourceRecord,
    cursor: last_sync_run.cursor,          # cursor-as-data, never job args
    lineage_job:
      AshDiscreteBusinessEvents.Lineage.job(:sync,
        source: :salesforce, stream: :opportunity
      )
  )

summary.landed  # NEW periods (identical re-observations are no-ops)
summary.cursor  # the water mark to persist on the sync-run record
```

### The fixture corpus (§8's honest demo input)

`priv/fixtures/salesforce/` — a synthesized but realistic dev-org-shaped
Opportunity export: **nine monthly Bulk 2.0 snapshots, 68
opportunities, 133 version transitions, 422 rows**, deterministic and
hash-derived (`generate_corpus.exs` reproduces the CSVs
byte-for-byte), **CC0-1.0** — data, free of rights. It deliberately
exercises: growth over time, stage transitions (the raw layer's periods
ARE the transitions), amount amendments (corrections), and one **late
arrival** (subject `…0003`'s March row carries a SystemModstamp older
than February's maximum).

Import it through the FULL land → map → ledger pipeline:

```elixir
{:ok, summary} =
  AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.import(
    host: MyApp.BusinessEvents,
    source: :salesforce,
    stream: :opportunity,
    source_record: MyApp.Platform.SourceRecord,
    ledger: MyApp.Platform.Ledger,
    mapping_name: :opportunity_stage_changed,
    mapping_version_resource: MyApp.Platform.MappingVersion
  )

summary # %{runs: 9, landed: 201, ledger_events: 201, corrections: 0, cursor: …, version_hash: …}
```

The import publishes → validates → **activates** the mapping version
first (provenance joins real `MappingVersion` rows), runs the sync
template per snapshot (real SourceRecord periods; identical re-sights
are temporal no-ops), and folds every landed record through the active
mapping — recording to the ledger ONLY at genuine truth transitions
(§7's corrections rule, folded against ledgered truth-points).
**Idempotent**: re-importing lands nothing and records nothing. The
test suite runs the corpus end-to-end — landed periods → ledger events
→ a BIZEV-8 projector → as-of reads mid-history.

## Corrections & late arrivals (BIZEV-9)

§7's ruling, mechanized: **corrections are events; the original is never
rewritten**. `Ledger.Corrections` holds the truth-point register — every
subject's ledgered `(occurred_at, data, event_id)` — and classifies each
mapped fact against it:

- an **unseen truth point** → a plain new event;
- the **same point, same data** → a replay folding away (identical
  content is never re-recorded);
- the **same point, different data** → a **superseding event** whose
  `supersedes_event_id` points at the current truth at that instant —
  a chained, append-only correction (a second correction supersedes the
  first: each correction is the new present).

The corpus import folds every mapped record through the register, so
**re-imports record nothing** and **retroactive revisions record exactly
the correction**. The fixture variant `priv/fixtures/salesforce/corrections/
revision-2026-06.csv` is the demo: subject `…0004`'s June close restated
(Closed Won → Negotiation) at the SAME SystemModstamp — the source
rewriting history. Armed via `FixtureCorpus.arm_revision!/2` (a restated
truth propagates to every later snapshot, as a rewritten source's would):

- the ledger shows **original + superseding event** (the original's row,
  data and chain hash untouched);
- the projector receives supersession **as data** — ops restate the
  truth and count the correction (the temporal projection reopens the
  period at the correction's own truth instant — BIZEV-8's machinery);
- **as-of reads answer honestly on both sides**: before the truth
  instant the pre-correction value stands unchanged; after it, the
  corrected value.

**Resync after cursor loss** (§7): the operator resets the cursor-as-
data, the full re-sync re-observes everything — identical snapshots
land nothing and record nothing (proven), drifted snapshots land
exactly one new period and exactly one superseding event per restated
truth point. Re-sync can never duplicate (delivery + source idempotency)
and never silently revises (corrections are visible events).

## Retention & GDPR (BIZEV-12, §9 risk 5)

Raw SaaS payloads are the erasable class; ledger canonical payloads are
**PII-minimal by design** (BIZEV-5's mapping rules — structural facts
only). This slice gives the raw layer its retention machinery.
Explicitly does NOT resolve ADR 0024 platform-wide.

**The partitioned raw layer**: SourceRecord's table is RANGE-partitioned
by `fetched_at` (the observation instant — §1.3's period basis),
monthly, hand-maintained (ash_postgres codegen does not model
partitioning). A DEFAULT partition catches unsliced months;
`Retention.ensure_partition!/2` creates an explicit month with its
per-partition identity exclusion (the identity is enforced WITHIN a
partition; cross-month overlaps are precluded operationally — periods
are `[fetched_at, next observation)` and backdated landings are
refused). `sim:` — nothing to do with partitions; that's BIZEV-10's
namespace.

**Drop-partition purge** — an explicit, audited operator action:

```elixir
AshDiscreteBusinessEvents.Retention.purge_before(
  MyApp.Platform.SourceRecord,
  MyApp.Platform.Ledger,
  before: DateTime.add(DateTime.utc_now(), -365, :day),
  region: :us,
  confirmed: true   # destructive; refuses without explicit opt-in
)
# {:ok, %{dropped: ["source_records_2026_01", …], rows: 4_213, tombstones: 3}}
```

Whole partitions drop at once (cheap, exact); each drop records a ledger
tombstone — `:"retention.partition_purged"` with the partition name and
row count. **Structural facts only** — never payloads (the leak rule).
The DEFAULT partition is never dropped (mixed data; purge it by erasure
or consciously by hand).

**Erasure-as-event**: `Retention.erase_subject/5` records the tombstone
FIRST — `:"retention.subject_erased"` with the subject descriptor — then
deletes the subject's raw rows through the table machinery. The tombstone
is the ledger's native answer to GDPR: it records THAT a subject's raw
data was purged, while the ledger's canonical facts stay (PII-minimal by
design).

**Tombstones in a host's ledger**: both actions take `record_opts:`
(the `tenant:`, `actor:` and `authorize?:` the ledger's `record` runs
with) and `context:` (where a host's ownership rides), so a multitenant
or owned ledger can hold them. `Retention.tombstone/5` is the
tombstone's record input as data, for a host whose erasure is not this
module's (a crypto-shred) and that records the same fact in the same
vocabulary.

**The honesty note (re-sync after erasure)**: erasure is LOCAL
retention, not source revision. The SOURCE still holds its data; the
next sync re-lands the subject's current state as NEW history (fresh
periods at the fetch instant). The erased instants stay erased — a
re-sync never resurrects purged history, it re-observes the present.

**PII minimization at mapping time**: the closed vocabulary now carries
a lint-level guard — canonical targets named like obvious direct
personal data (`email`, `phone`, `ssn`, …) are REFUSED at compile time;
PII belongs in the raw layer, and `unmapped_because` is the documented
way to name the gap. Not a PII oracle — it catches the obvious,
cheaply, at compile time.

## The BPMN trigger bridge (BIZEV-13, §5.2)

ADR 0030's EventSource adapter pattern, with the audit trigger's division
of labor — **nudge on append + sweep for completeness**:

- **Nudge on append, best-effort**: after a fresh ledger append commits,
  the configured handler's `nudge/1` receives the full ledger row (the
  event kind in `action`, subject/correlation keys, `process_ref`, provenance,
  data). A failure is logged and swallowed — the record stands, the
  sweep recovers. Simulated rows never nudge (the twin stays out of the
  real machinery); delivery-collapsed retries don't re-nudge.
- **Sweep for completeness**: `Triggers.sweep/3` walks the region's
  commit-order feed from the handler's dispatch cursor (an engine
  checkpoint, keyed `triggers:<handler>.<region>`), nudging every event
  and advancing per event. At-least-once: a failed nudge stops the
  sweep at that event — the cursor stands, the next sweep retries.
  Handlers must be idempotent on the BPMN side (dispatch correlates by
  subject/process_ref).

**No ash_bpmn dependency**: hosts wire the adapter —

```elixir
config :ash_discrete_business_events, :trigger_handler, MyApp.Bpmn.EventSource

defmodule MyApp.Bpmn.EventSource do
  @behaviour AshDiscreteBusinessEvents.Triggers.Handler
  # the ledger row carries the event kind in `action` (an atom)
  def nudge(event), do: MyApp.Bpmn.Runtime.dispatch(event.action, event)
end

# the completeness sweep (the host's periodic job):
AshDiscreteBusinessEvents.Triggers.sweep(MyApp.Platform.Ledger, :us)
```

**Process context as data (§5.2's slots)**: the ledger row carries an
optional `process_ref` — the BPMN-side correlation pointer for
process-relevant events — set by the mapping's `process_key` (a payload
path; the value lands on the canonical output as `:process_ref` and on
the ledger row) or by the caller. Process context beyond the pointer
lands in the row's existing `context` map, as data.

## The honest demo path (§8)

The demo discipline, stated as a rule: **internal event history and
external event history are DIFFERENT sources, labeled as such, and never
merged silently.**

- clinic-demo's revenue/forecast expression reads **internal
  appointment history** — an internal event source, already
  ash_events-logged. That is not BIZEV data and demos must say so.
- BIZEV's external history is the **Salesforce fixture corpus** — every
  external row in a demo traversed the full land → map → ledger path
  (real SourceRecord periods, real ledger rows with provenance). No
  demo ever shows external events that did not traverse the ledger.
- Any surface listing both must label the source (internal vs external
  via the ledger, simulated vs real via BIZEV-10's
  `simulation_runs/1`/twin-shape contract).

Production Salesforce connects only after the fixture path is boring.

## The simulation twin (BIZEV-10)

The simulation twin is **one macro, two modules, two tables**: declaring
`{:ledger, opts}` emits the real ledger AND its `SimulationEvent` twin
(same §1.4 columns; sim rows additionally carry `simulated: true` and a
required `simulation_run` label, set at record time). Simulated events
are structurally unreachable from the real side — the isolation is the
schema, not a filter anyone must remember. The ticket's acceptance
criteria, closed:

- **AC-1 — rebuilds never manufacture history**: real projector
  rebuilds-from-zero read the real ledger's feed only; simulated events
  (even same-kind, same-shape ones) never appear in a rebuilt state.
  Pinned at the data layer *and* at the cache layer.
- **AC-2 — the cache namespace extends the isolation**: simulation
  drains key their checkpoints `sim:<name>.<region>:<run>` — real
  drains key `<name>.<region>` — so a simulation drain's cursor can
  never alias, satisfy, or be satisfied by a real drain's checkpoint on
  the same projector and region, and two simulation runs never share
  one. `sim:` is a reserved prefix for real projector names.
  A projector's `drain_simulation/3` (defined by
  `use AshDiscreteBusinessEvents.Projections`; or `Drain.simulation/4`)
  is the supported entry; the twin feed filters on the run label the rows
  carry.
- **AC-3 — unmistakable by shape, labeled by contract**: the package
  ships no UI, so the "visibly labeled" requirement lands as the
  label/query contract: every twin row carries `simulated: true` +
  `simulation_run`; a row without a run label cannot come from the
  twin, and a row in the real ledger cannot be simulated.
  `AshDiscreteBusinessEvents.simulation_runs/1` is the supported read —
  one map per run (`simulation_run`, `events`, `subjects`,
  first/last observed), for any surface that lists event history.

The regression suite lives in `test/simulation_isolation_test.exs` —
its passing is the closure statement.

**The twin on the host's base.** By default the twin is a bare
`use Ash.Resource` with the two ledger extensions: none of the host's
tenancy, ownership, changes or policies. A host whose ledger stands on
its own base passes that base as `simulation_base: {MyBase, use_opts}`,
and the twin is emitted as `use MyBase, use_opts` — so the host's grant
union governs simulated events as it governs real ones. `use_opts` must
bring both ledger extensions (the twin refuses to compile otherwise);
`simulation_runs/2` takes the read's options for a multitenant twin.
`test/simulation_host_base_test.exs` pins it.

## Projections (BIZEV-8)

The ledger IS an AshEvents log, so the projector engine drains business
events **unchanged**: `project "opportunity.stage_changed", fn event ->
ops end` — the event kind rides the log's `action`, the subject's
external id rides `record_id`, and the handler sees the full §1.4 row
(region, occurred_at, supersedes_event_id, provenance, sequence, data).

```elixir
defmodule MyApp.Projections.PipelineHistoryProjector do
  use AshDiscreteBusinessEvents.Projections,
    name: "pipeline_history_v1",
    event_log: MyApp.Platform.Ledger,
    projection_resource: MyApp.Projections.PipelineHistory

  grain fn event -> %{region: event.region, subject: event.record_id} end

  project "opportunity.stage_changed", fn event ->
    [{:set, :stage, event.data["to_stage"]}]
  end
end

# drain one region's commit-order feed (idempotent — the checkpoint is
# the cursor; call it from the sync job template):
MyApp.Projections.PipelineHistoryProjector.drain(:us)
```

The projection target is an ordinary `AshEvents.Projections.ProjectionResource`
(`grain_fields`, the ops vocabulary: `{:set, :stage, v}`, `{:increment,
:corrections, n}`, …). **Declare `temporal` on it and the projector's
writes become periods** (§4: canonical projections ARE temporal,
host-side): the drain writes `as_of event.occurred_at` — the source's
truth time — so a late arrival reopens history at the instant the truth
changed, and a correction (an event with `supersedes_event_id`) restates
without rewriting. "Pipeline value of account X at T" is then
`Ash.Query.as_of/2` on the projection.

**Why the package owns the drain** (and the engine's Server does not run
over the ledger): the engine scans the log by GLOBAL id — a silent
cross-region merge (§6) — and selects the origin's columns the ledger
does not carry. `AshDiscreteBusinessEvents.Projections.Drain` drains the
per-region commit-order `feed` (sequence order is commit order per
region), reusing the engine's Projector DSL, ProjectionResource actions,
`Checkpoint` (keyed per projector AND region) and `DeadLetter` verbatim.

**The replay-equivalence gate (the S1-67-family unknown, now closed
positive):** a ledger-driven lifecycle — multiple subjects, stage
progressions, a late arrival, a supersession — drained live, then wiped
and re-drained from scratch, yields **byte-identical periods** (bounds,
content and counters; the write's wall clock differs by design, the
periods do not). Determinism is a property of the engine + feed order,
pinned by test; as-of consumers may rely on rebuilt projections.

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
