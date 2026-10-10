# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger do
  @moduledoc """
  The ledger — a dedicated `AshEvents.EventLog` whose rows ARE canonical
  discrete business events (design §1.4, §5.1). Emitted onto the host's
  base by `use AshDiscreteBusinessEvents.Resources, :ledger`, together
  with its simulation twin (§5.6).

  ## The three clocks, made columns

    * `occurred_at` — source truth time (required input; it repurposes
      the AshEvents column of the same name: for business events the
      log's "when it happened" IS the source's truth time, and replay's
      point-in-time filtering then answers "the ledger as of T").
    * `observed_at` — when we learned (the write's clock).
    * `sequence` — commit order within the region (the lock's property).

  Every consumer picks its clock explicitly; late arrival is ordinary.

  ## The row, by concern

  what: `action` carries the event kind (projector-dispatchable as-is —
  the projector DSL's `project "kind"` matches the atom form, converted
  at compile time) and `data` the canonical mapped payload. The subject
  and actor ride as DESCRIPTORS — never foreign keys: `subject_type`/
  `subject_external_id`/`subject_stream`, `actor_type`/
  `actor_external_id`/`actor_display` (and `subject_external_id` doubles
  as the log's `record_id`, the machinery's subject key, with
  `subject_resource` routing replay). why: `context` (what the source
  supplied) and `provenance` (mapping_name, mapping_version_hash,
  source_record_id — the mapping behind every row, reconstructable from
  the row alone). corrections: `supersedes_event_id` — corrections are
  new rows, never rewrites. delivery: `delivery_key`, idempotent per
  region. region: `region` + `residency_tag`.

  ## The machinery, owned here

    * **Commit order**: `RegionLockKeyGenerator` + `Changes.StampEvent`
      take the per-region advisory xact lock BEFORE insert, so bigserial
      `sequence` order is commit order per region — three caveats
      documented on the generator, pinned by the permanent concurrent
      writers test.
    * **Tamper evidence**: per-region hash chains, written by a
      `BEFORE INSERT` trigger (`ChainSQL`), verified in SQL with the
      same expression (`VerifyChains`, `mix bizev.verify_chains`).
    * **Append-only**: update/destroy actions do not exist; the emitted
      immutability trigger refuses UPDATE/DELETE at the database.
      AshEvents' stock `:create` is removed — `record` is the only
      write path.
    * **Region discipline**: plain reads require a region; the one gated
      exception, `cross_region_read`, writes a disclosure row per
      queried region before scanning.
    * **Isolation**: the simulation twin is a separate module and table;
      simulated events are unreachable from the real ledger's
      projector/rebuild path by construction.
  """
end
