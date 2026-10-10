# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord do
  @moduledoc """
  The temporal raw-landing layer (design §1.3) — the surface the
  `use AshDiscreteBusinessEvents.Resources, :source_record` macro emits
  onto the host's own base.

  One record per `(source, stream, external_id, region)` identity, with
  version history as periods: `valid_at = [fetched_at, next observation)`.
  Adopted from the dogfood's `SourceObject` pattern (immutable raw
  payload at the boundary, cursor-as-data, sync-reset as an explicit
  action, idempotent landing) with three upgrades:

    * **Append-only with change history — temporal.** Changed content
      splits the period at the observation instant; identical content is
      a no-op. "What did Salesforce say the stage was on Oct 1" is an
      index-backed containment read (`SourceRecord.at/5`), not a replay.
    * **Stream and region in the identity.** Two streams landing the same
      external id are two records, structurally — the E1 known gap is
      closed by the identity, not by projector-side filtering.
    * **Zone/residency admission on the land path.** The land action
      refuses until the observation is tagged, checked where data is
      first written (ADR 0042) — never at egress.

  There are NO hand-rolled `valid_from`/`valid_until` columns: the
  temporal extension owns validity (`docs/REVIEW.md`, §4). `recorded_at`
  is the wall clock of when a version was written; `fetched_at` is the
  observation instant the period opens at; source-side truth time lives
  in the raw payload until mapping extracts it (BIZEV-5) into the
  ledger's `occurred_at`.
  """
end
