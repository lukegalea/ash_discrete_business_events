# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.RegionLockKeyGenerator do
  @moduledoc """
  The region-keyed advisory-lock generator (design §1.4) — the BIZEV
  sibling of `AshEvents.AdvisoryLockKeyGenerator.Default`, which keys on
  the audit log's tenant. Implemented against the same behaviour, so it
  plugs into the event-log configuration and the lock is acquired by the
  same machinery shape: `pg_advisory_xact_lock($1, $2)` with a
  two-element list.

  Key derivation is deterministic across nodes: a fixed BIZEV namespace
  integer plus `:erlang.phash2/2` of the region, bounded to 31 bits. The
  namespace separates this package's lock space from other consumers of
  the same database's advisory-lock space (over-serialization is the
  failure mode of a collision, never lost ordering — both parties would
  simply wait).

  ## The property, and its three caveats (design §1.4, restated here)

  Because the lock is taken *before* the row is inserted and is
  `xact`-scoped, a second transaction for the same region cannot be
  assigned its `sequence` (bigserial, at INSERT) until the first has
  committed. So **within one region, `sequence` order is commit order** —
  which is what makes `sequence` usable as a change-feed cursor at all. A
  plain bigserial is otherwise the canonical wrong thing to build a feed
  on. Three limits, each of which someone will otherwise assume away:

    * **It is per region, and only across writers that take the lock.**
      Direct writes through `:record` take it; a `psql` INSERT does not.
      The chain trigger would still fire, but the ordering claim belongs
      to the lock.
    * **It depends on the lock being xact-scoped and taken before the
      insert.** Both live in this package's record change, in the same
      transaction as the insert. If that moves — upstream or here —
      consumers skip events *silently*, which is why the concurrent
      writers test is permanent (design risk 2).
    * **It is our mechanics.** Unlike the audit log (whose lock is ash_
      events'), the ledger owns this change — which is also why the
      caveat can be honest here: swap the generator or the change and the
      property is yours to re-prove.
  """

  use AshEvents.AdvisoryLockKeyGenerator

  @namespace 1_276_543_210

  @doc """
  The advisory key for a ledger changeset — `[namespace, region_hash]`.
  """
  @impl true
  def generate_key!(changeset, _default) do
    region =
      Ash.Changeset.get_attribute(changeset, :region) ||
        Ash.Changeset.get_argument(changeset, :region) ||
        raise ArgumentError,
              "the ledger's advisory lock is keyed by region, but no region was supplied"

    key_for(region)
  end

  @doc """
  The advisory key for `region` — public so operators and tests can hold
  the same lock the record path takes.
  """
  @spec key_for(atom()) :: [integer(), ...]
  def key_for(region) when is_atom(region) do
    [@namespace, :erlang.phash2(region, 2_147_483_647)]
  end
end
