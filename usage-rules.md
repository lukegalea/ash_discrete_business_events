<!-- SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events> -->
<!-- SPDX-License-Identifier: MIT -->

# Usage rules

Rules for working with `ash_discrete_business_events`, maintained for
[`usage_rules`](https://hex.pm/packages/usage_rules) sync. The package
contract below is binding on every change — in this repository and in
consumers. (Grows with each slice; what is here is already binding.)

## What the package is

The canonical discrete business-event ledger: `SourceRecord` raw landing
with temporal version history (BIZEV-3), a dedicated chained event ledger
with per-region commit-order sequences (BIZEV-4), and mappings-as-data
with per-row provenance (BIZEV-5) — the land → map → ledger boundary
external SaaS history enters the platform through.

## What it never does — do not make it

- **Never hand-roll validity bookkeeping.** Any new `valid_from`/
  `valid_until` columns on BIZEV resources are a design error (design §4).
  `SourceRecord`'s validity is the temporal extension's `valid_at` period
  (`strategy :context`); the ledger is create-only and forbidden-by-mandate
  from being temporal at all. Corrections are NEW ledger rows via
  `supersedes_event_id` — never rewrites, never validity ranges.
  `docs/REVIEW.md` rejects this on sight.
- **Never merge regions silently.** Chains, advisory locks, sequences and
  cursors are per-region, structurally (§6). A global chain or global
  cursor is a silent merge — the partition is the honesty. Cross-region
  reads are one gated, disclosed operator action, never the default.
- **Never put cursors in job args.** Cursors are data: on SourceRecord
  rows and sync-run records (§2.3). `reset_cursor` is an explicit
  action; wrong-cursor conditions are operator actions, never silent
  rewinds. A reset is a visible historical event (the temporal split),
  never an erasure.
- **Never treat external ids as identities.** Subject/actor rows carry
  descriptors (`type`, `external_id`, `stream`/`display`) — linking to
  internal entities is projection/entity-resolution work, never done at
  land (VendorPM Law 1, ADR 0017). The SourceRecord's `external_id` is
  an idempotency key inside the identity tuple, not a join key.
- **Never ship a concrete resource module for hosts to adopt.** The
  resources are resource macros (`use AshDiscreteBusinessEvents.Resources,
  :source_record` / `:ledger`) so hosts instantiate them on their own base
  and their policies apply natively (§1.1).
- **Never emit per-row lineage.** Lineage is at job granularity — the sync
  run or webhook batch is the unit (§3). The run-id derivation is
  exported and shared by construction, and the leak rule (no actor,
  tenant, customer or filter values in emitted events) is a mechanized
  acceptance test.
- **Never silently degrade on budget exhaustion.** Rate budgets are
  surfaced data; exhaustion is a visible FAIL — the feed pauses, it does
  not degrade (§7).

## Working with the raw layer (BIZEV-3)

- Instantiate `SourceRecord` via the resource macro on YOUR base — never
  adopt a concrete module; the macro is what lets your policies govern
  the land and read actions (§1.1).
- Land through `land/1` only. It is the typed boundary: admission
  (refuse-until-tagged, tag must admit into the target region) and,
  later, ownership/tenancy/lineage attach here. No staging-table side
  doors.
- Landing is idempotent — re-running a sync is safe: identical content
  (payload AND cursor) is a no-op; changed content opens a new period.
  Never write an upsert-refresh-in-place path beside it; that is the
  exact defect ADR 0049 names.
- The land decision compares the version valid **at `fetched_at`** — a
  late duplicate of already-observed content is a no-op. Landings whose
  `fetched_at` precedes an identity's known history are refused
  (taps deliver in cursor order; backdated reconstruction is BIZEV-9).
- Residency is fixed at admission. Content changes re-open periods;
  they do not re-litigate the tag.
- As-of questions go through `at/5` (index-backed containment), never
  by re-reading and filtering in the consumer.
- Identity attributes must be globally unique across concurrent tests —
  two tests landing the same external id deadlock on the exclusion
  constraint's row locks (the ash:testing deadlock rule).

## Working with the DSL

- Sources and mappings are declared on a host module
  (`use AshDiscreteBusinessEvents, domains: [...]`); read them back
  through `AshDiscreteBusinessEvents.Info` — never by grepping the host
  module or re-parsing source.
- The DSL vocabulary is closed and schema-verified: an unknown option is
  a compile error. Extend it by amending the schema and citing the design
  section — never by accepting `:any`-typed escape hatches.
- `region` is required on every source (§6). A source without a region
  has no honest place to land.

## Status

BIZEV-2 froze the contracts; BIZEV-3 delivered the raw layer. The ledger
lands in BIZEV-4, the mapping engine in BIZEV-5. The row shapes are
pinned by the fixture-pinned contract tests in `test/` — amending them
requires amending those tests and citing the design section that
motivates the amendment.
