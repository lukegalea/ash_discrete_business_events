<!--
SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
SPDX-License-Identifier: MIT
-->

# Review checklist — `ash_discrete_business_events`

Every change to this package is reviewed against this list. Each item
cites the design section that rules it (`~/system-one-program/research/
bizev-design.md`, BIZEV-1, oracle design committed by the orchestrator).
A review that finds one of these violated **rejects the change** — it is
a design error, not a style difference.

## The checklist

### 1. No hand-rolled validity bookkeeping — reject on sight

Any new `valid_from`/`valid_until` columns on BIZEV resources are a
**design error** (§4):

- The **ledger** is create-only. A discrete event is an immutable fact
  that happened; nothing about the row's own record ever changes, and
  period opens at creation and never closes. Temporal split-writes would
  fight the append-only trigger, the per-region chain, and the
  commit-order sequence for zero gain.
- **SourceRecord** gets validity from the *temporal extension*
  (`strategy :context`, `valid_at` observation periods) — not from
  hand-written columns or hand-written period math.
- **Projections** are temporal host-side, by declaring `temporal` on the
  projection resource.

The correct review response to a `valid_from`/`valid_until` column in a
diff is: reject, and point the author at §4.

### 2. Corrections are events, never rewrites

A correction derives a **new ledger row** with `supersedes_event_id` set;
the original is never rewritten — the chain's integrity depends on it
(§7). Reject any update action on the ledger, any `ON CONFLICT DO UPDATE`
against ledger rows, or any "edit the event" feature.

### 3. Stream and region live in the identity

The SourceRecord identity is period-aware
`(source, stream, external_id, region)` (§1.3). An identity missing
stream or region is the E1 known gap reintroduced. Reject.

### 4. Region separation is structural

Per-region hash chains, per-region advisory locks, per-region sequences,
per-region feed cursors (§6). A **global** chain, lock or cursor is a
silent merge — reject. Cross-region reads are one gated, disclosed
operator action (`cross_region_read`), never a default read path; a
ledger read action without a region filter is a defect.

### 5. Commit-order sequence means lock-then-insert

The `record` action takes `pg_advisory_xact_lock(region_key)` **before**
insert, keyed per region (§1.4). A plain bigserial is the canonical wrong
thing. Changes to lock timing/scope must ship with the concurrency
measurement test (inverted-commit under concurrency) still passing, and
the caveat restated in the docs.

### 6. Cursors are data; sync-reset is an operator action

Cursors live on SourceRecord rows and sync-run records, never in Oban
args (§2.3). `reset_cursor` is an explicit action; wrong-cursor
conditions are operator actions, never silent rewinds (§2.4). Reject
cursor state in job args, env vars, or process dictionaries.

### 7. Subject/actor are descriptors, not identities

The ledger carries `subject_type`/`subject_external_id`/`subject_stream`
and `actor_type`/`actor_external_id`/`actor_display` — no FKs to internal
entities, no resolution at land (§1.4, VendorPM Law 1, ADR 0017). Reject
columns like `person_id` or `account_id` on the ledger. The two
idempotency layers stay separate: `delivery_key` (delivery level) below
source-level idempotency.

### 8. Resource macros, not concrete modules

Hosts instantiate SourceRecord/Ledger/SimulationEvent via
`use AshDiscreteBusinessEvents.Resources, :source_record` / `:ledger`
(§1.1). Spark builds policies at the package's compile time, so concrete
modules can't take host policy blocks. Reject any change that turns the
macros into concrete resource modules, or moves resource definitions out
of macro reach.

### 9. Raw layer is version-history-preserving

Immutable raw payload at the boundary, temporal version history, no-op on
identical re-observation, new period on changed content (§1.3, §2).
Reject upsert-refresh-in-place — the exact defect ADR 0049 names.

### 10. Zone/residency admission happens at land

Admission is checked where data is first written, not at egress; the land
action refuses until tagged (§1.3, ADR 0042). A new landing path that
doesn't check residency is the E4 TODO re-opened. Reject.

### 11. Lineage at job granularity; the leak rule is mechanized

No per-row lineage notifiers on raw or ledger rows — the sync run or
webhook batch is the unit, and START/COMPLETE/FAIL are emitted by the job
templates with the exported run-id contract (§3). Structural naming
vocabulary only (`bizev.sync.<source>.<stream>` etc.); stream ranges are
facet-level counts, never boundary values. Any new emitted field needs the
leak-test proof that actor/tenant/customer/filter values cannot reach it.

### 12. Simulation isolation is structural

The ledger macro emits `Ledger` and `SimulationEvent` from one
declaration — two modules, two tables; projectors, EventSources, cursors
and chains bind to the module (§5.6, SIM-NAMESPACE-ISOLATION). Reject
"just add a `simulated` boolean" designs, and reject any shared-table
query-filter discipline as the isolation mechanism.

### 13. The dependency boundary

The package depends on ash, ash_postgres, spark, the ash_events fork (then
upstream), and ash_open_lineage. It does **not** depend on ash_strangler
(shape adopted, dependency declined — §5.4), ash_bpmn (hosts wire the
adapter — §5.2), ash_decisions (optional integration — §5.3), Nango (host
edge), or Meltano (workbench) (§8). Reject new dependencies not in that
list.

### 14. PII discipline at the boundary

Minimization at mapping time; raw payloads partitioned with drop-partition
purge as an explicit audited operator action; erasure-as-event tombstones
(§9.5). Reject retention features that silently delete or that purge
without an event.

---

*Source of authority: the BIZEV-1 design (§ references above). If the
design and a proposed change conflict, the design wins until a ruled
amendment changes it — surface the conflict, don't improvise.*
