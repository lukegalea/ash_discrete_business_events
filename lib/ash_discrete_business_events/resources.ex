# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Resources do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # The `:source_record` macro's quote IS the deliverable: the whole
  # temporal raw-landing resource, macro-generated on the host's base so
  # the host's policies govern its actions natively (ADR 0035's reversal
  # clause, §1.1). A resource-length quote is the point, not a smell.
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
    quote location: :keep do
      # ── Temporal raw layer (design §1.3, the ADR 0049 mandate) ──────────
      # "Append-only" is version-history-preserving: every landed
      # observation is a period; changed content SPLITS the period at the
      # observation instant and history is never overwritten. The period
      # (`valid_at`) and the wall-clock stamp (`recorded_at`) are added by
      # ash's temporal transformer — both flagged `generated?`/`writable?`
      # false so generator shapes exclude them (the machinery is not
      # input).
      temporal do
        strategy :context
        attribute :valid_at
        recorded_at :recorded_at
      end

      attributes do
        uuid_primary_key :id

        attribute :source, :atom do
          allow_nil? false
          public? true

          description "The declared source — first element of the identity tuple."
        end

        attribute :stream, :atom do
          allow_nil? false
          public? true

          description """
          The stream the observation landed in — second element of the
          identity tuple. Stream-in-the-identity is structural (the E1
          known gap, fixed here): two streams landing the same external id
          are two records, no projector-side filtering required.
          """
        end

        attribute :external_id, :string do
          allow_nil? false
          public? true
          constraints max_length: 512

          description "The source system's own id for the object, verbatim. An idempotency key, never an identity (VendorPM Law 1)."
        end

        attribute :region, :atom do
          allow_nil? false
          public? true

          description """
          The region the observation was admitted into — fourth element of
          the identity tuple. CA and US never merge silently (§6).
          """
        end

        attribute :residency_tag, :string do
          allow_nil? false
          public? true

          description """
          The residency declaration admission checked at land — refuse
          until tagged (ADR 0042). Admission happens on the land path,
          checked where data is first written, never at egress.
          """
        end

        attribute :raw_payload, :map do
          allow_nil? false
          public? true

          description """
          The record exactly as the source emitted it, uninterpreted —
          byte-for-byte fidelity in the JSON sense (semantic content
          preserved; canonical rows derive, never replace).
          """
        end

        attribute :source_metadata, :map do
          public? true
          description "Tap/bookkeeping metadata: adapter name, sync run, replication keys."
        end

        attribute :cursor, :map do
          public? true

          description """
          The source cursor in effect for this observation. Cursor-as-data
          (§2.3): cursors live on SourceRecord rows and sync-run records,
          never in job args.
          """
        end

        attribute :fetched_at, :utc_datetime_usec do
          allow_nil? false
          public? true

          description """
          When the tap emitted the record — the observation instant, and
          the PERIOD BASIS: `valid_at = [fetched_at, next observation)`.
          Knowledge time is the raw layer's dimension; source-side truth
          time (e.g. SystemModstamp) stays in the raw payload and is
          extracted by mapping (BIZEV-5) into the ledger's occurred_at.
          """
        end
      end

      identities do
        # Period-aware `WITHOUT OVERLAPS` (the migration generator emits a
        # GiST exclusion on temporal resources): one open period per
        # `(source, stream, external_id, region)` at any instant —
        # superseded observations share the key across non-overlapping
        # periods, which is exactly the history the layer preserves.
        identity :unique_observation, [:source, :stream, :external_id, :region]
      end

      actions do
        read :read do
          primary? true

          description "The observations as of now — with strategy :context, the current version of every identity."
        end

        read :by_identity do
          description "The current observation for one identity tuple."
          get? true

          argument :source, :atom, allow_nil?: false, public?: true
          argument :stream, :atom, allow_nil?: false, public?: true
          argument :external_id, :string, allow_nil?: false, public?: true
          argument :region, :atom, allow_nil?: false, public?: true

          # The identity filter lives in a preparation, not a `filter
          # expr` here: inside a macro-emitted quote, `^arg(...)` would be
          # consumed as an unquote. The prep applies the same constraint
          # at run time against the action's arguments.
          prepare {AshDiscreteBusinessEvents.SourceRecord.Preparations.ByIdentity, []}
        end

        read :at do
          description """
          What did the source say at T — the design's Oct-1 question, as an
          index-backed containment read: the version whose period contains
          the instant (`valid_at @> as_of`, served by the GiST exclusion
          index).
          """

          get? true

          argument :source, :atom, allow_nil?: false, public?: true
          argument :stream, :atom, allow_nil?: false, public?: true
          argument :external_id, :string, allow_nil?: false, public?: true
          argument :region, :atom, allow_nil?: false, public?: true
          argument :as_of, :utc_datetime_usec, allow_nil?: false, public?: true

          # Same reasoning as `:by_identity`: the identity filter and the
          # time pin are applied by the preparation at run time.
          prepare {AshDiscreteBusinessEvents.SourceRecord.Preparations.At, []}
        end

        create :open_period do
          description """
          First landing for an identity — opens the observation period at
          the write's `as_of`. Called by `:land`; the admission change
          runs here because land is where data is first written (ADR
          0042).
          """

          accept [
            :source,
            :stream,
            :external_id,
            :region,
            :residency_tag,
            :raw_payload,
            :source_metadata,
            :cursor,
            :fetched_at
          ]

          change {AshDiscreteBusinessEvents.SourceRecord.Changes.AdmitResidency, []}
        end

        update :replace_observation do
          description """
          Changed content: SPLITS the version valid at the write's `as_of`
          — the superseded payload keeps its period, the new observation
          takes over from there. History is never overwritten. Residency
          is not re-admitted: the tag was checked at land and is a
          property of where the row was admitted, not of its content.
          """

          accept [:raw_payload, :source_metadata, :cursor, :fetched_at]
        end

        update :advance_cursor do
          description """
          Persist the cursor a completed run ended on, onto the current
          version. On the temporal raw layer this is an ordinary split:
          the prior cursor value keeps its period, the advanced one takes
          over — cursor history is observation history, never a rewrite.
          """

          accept [:cursor]
        end

        update :reset_cursor do
          description """
          Sync-reset (§2.4, the dogfood ruling verbatim): drop the stored
          cursor so the next run re-observes from the beginning.
          Wrong-cursor conditions (410 Gone, invalid sync token) are an
          explicit operator action, never a silent rewind. As a temporal
          split, the pre-reset cursor keeps its period — the reset is
          visible history, not an erasure. Re-sync then cannot duplicate
          (identical content lands as a no-op) and cannot silently revise
          (changed content opens a new period).
          """

          accept []
          change set_attribute(:cursor, nil)
        end

        action :land, :struct do
          description """
          Idempotent landing of one raw observation — the typed boundary
          external data enters through (§1.2). Ownership, tenancy, region
          admission and lineage attach here, at land.

          Decision, at `as_of = fetched_at`:

            * no version of the identity exists at that instant → the
              observation OPENS the period (first landing)
            * the version there carries the same payload and cursor →
              temporal no-op (the VPM-49 import-rework pattern): nothing
              is written, the existing record is returned
            * it differs → the observation SPLITS: changed content opens
              a new period, history preserved

          Runs in one transaction (read-decide-write). Landing an
          observation whose `fetched_at` precedes known history for the
          identity is refused, loudly — taps deliver in cursor order;
          backdated-history reconstruction is BIZEV-9's corrections work.
          """

          constraints instance_of: __MODULE__
          transaction? true

          argument :source, :atom, allow_nil?: false, public?: true
          argument :stream, :atom, allow_nil?: false, public?: true
          argument :external_id, :string, allow_nil?: false, public?: true
          argument :region, :atom, allow_nil?: false, public?: true
          argument :residency_tag, :string, allow_nil?: false, public?: true
          argument :raw_payload, :map, allow_nil?: false, public?: true
          argument :source_metadata, :map, allow_nil?: true, public?: true
          argument :cursor, :map, allow_nil?: true, public?: true
          argument :fetched_at, :utc_datetime_usec, allow_nil?: false, public?: true

          run {AshDiscreteBusinessEvents.SourceRecord.Land, []}
        end
      end

      code_interface do
        define :land, action: :land

        define :by_identity,
          action: :by_identity,
          args: [:source, :stream, :external_id, :region],
          not_found_error?: false

        define :at,
          action: :at,
          args: [:source, :stream, :external_id, :region, :as_of],
          not_found_error?: false

        define :advance_cursor, action: :advance_cursor, args: [:cursor]
        define :reset_cursor, action: :reset_cursor
      end
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
