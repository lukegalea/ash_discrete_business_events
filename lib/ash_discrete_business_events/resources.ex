# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Resources do
  @moduledoc """
  The resource-macro entry points hosts use to instantiate BIZEV's
  resources *on their own base*.

      defmodule MyApp.Platform.SourceRecord do
        use Ash.Resource,
          domain: MyApp.BusinessEvents,
          data_layer: AshPostgres.DataLayer

        use AshDiscreteBusinessEvents.Resources, :source_record
      end

  **Resource macros, not concrete modules** — the single most important
  packaging lesson from ash_compliance, and load-bearing here (§1.1):
  Spark builds policies at the *package's* compile time, so concrete
  resource modules can't take host policy blocks. Macros inherit the
  host's grant union natively. Landing external data is exactly the kind
  of action a tenant must be able to govern, so the resource surface is
  macros from day one and stays macros.

  The ledger macro additionally emits the `SimulationEvent` twin from the
  same declaration (§5.6, SIM-NAMESPACE-ISOLATION): one schema, two
  modules, two tables — simulated events can never be picked up by a
  real projector's rebuild because the real projector never reads that
  table. That mechanism lands in BIZEV-10.
  """

  @doc false
  defmacro __using__(which)

  defmacro __using__(:source_record) do
    quote do
      # TODO(BIZEV-3): the temporal raw-landing layer (§1.3):
      #
      #   * immutable raw payload at the boundary, preserved byte-for-byte
      #     per version; canonical rows derive, never replace
      #   * `temporal do strategy :context; attribute :valid_at end` with
      #     `valid_at = [observed_at, next observation)` — append-only
      #     version history, never upsert-in-place (the ADR 0049 defect)
      #   * period-aware `WITHOUT OVERLAPS` identity on
      #     `(source, stream, external_id, region)` — stream and region
      #     in the identity, structurally
      #   * identical content re-observed is a no-op; changed content
      #     opens a new period
      #   * cursor-as-data (`fetched_at` is the period basis); source-side
      #     truth time stays in the payload, extracted by mapping
      #   * zone/residency admission checked on the land path — refuse
      #     until tagged
      #   * `reset_cursor` as an explicit operator action
      #
      # Note: NO hand-rolled valid_from/valid_until columns — the temporal
      # extension owns validity (docs/REVIEW.md, §4).
      :ok
    end
  end

  defmacro __using__(:ledger) do
    quote do
      # TODO(BIZEV-4): the dedicated AshEvents ledger (§1.4), plus the
      # SimulationEvent twin (§5.6):
      #
      #   * rows ARE canonical discrete business events — event_kind +
      #     canonical data, subject/actor descriptors (never FKs),
      #     occurred_at vs observed_at vs commit-order sequence,
      #     provenance per mapping rule, supersedes_event_id,
      #     delivery_key idempotency, region + residency_tag
      #   * `record` action takes the per-region advisory xact lock
      #     BEFORE insert, so sequence order is commit order
      #   * per-region hash chain (SHA-256 over row + previous per-region
      #     hash), verification mix task
      #   * append-only trigger; create-only — corrections are new rows
      #   * `cross_region_read` as one gated, disclosed operator action
      #   * a second generated module/table for simulated events
      #     (module-bound projectors/chains/cursors)
      #
      # Note: create-only means NO valid_from/valid_until — the ledger is
      # not temporal (docs/REVIEW.md, §4).
      :ok
    end
  end

  defmacro __using__(other) do
    known = [:source_record, :ledger]

    raise ArgumentError,
          "use AshDiscreteBusinessEvents.Resources expects :source_record or :ledger, " <>
            "got: #{inspect(other)} (known: #{inspect(known)})"
  end
end
