# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Resources do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # The macros' quotes ARE the deliverable: whole resources,
  # macro-generated on the host's base so the host's policies govern
  # their actions natively (ADR 0035's reversal clause, §1.1). A
  # resource-length quote is the point, not a smell.
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

  ## `:source_record`

  The temporal raw-landing layer (§1.3). See
  `AshDiscreteBusinessEvents.SourceRecord`. The host declares the
  resource's base (`use Ash.Resource`, domain, data layer, `postgres`
  block) and the macro emits everything else.

  ## `:ledger`

  The dedicated event ledger (§1.4) plus its simulation twin (§5.6,
  SIM-NAMESPACE-ISOLATION) — **one declaration, two modules, two
  tables**. The host declares the base with the AshEvents extension:

      defmodule MyApp.Platform.Ledger do
        use Ash.Resource,
          domain: MyApp.BusinessEvents,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshEvents.EventLog]

        use AshDiscreteBusinessEvents.Resources, {:ledger,
          repo: MyApp.Repo,
          table: "ledger_events",
          simulation_table: "ledger_simulation_events",
          domain: MyApp.BusinessEvents}

        policies do
          # your grants govern record / read / cross_region_read natively
        end
      end

  Options (repo, table, simulation_table required; the migration's chain
  and immutability triggers are emitted per table from these names, so
  the macro owns the `postgres` block for the ledger):

    * `:repo`, `:table` — the ledger's repo and table (the chain and
      immutability triggers are named after the table).
    * `:simulation_table` — the twin's table. The twin module is emitted
      as `Module.concat(host, SimulationEvent)`; its rows carry
      `simulated: true` and a required `simulation_run` label. The twin
      has its OWN per-region chains and its OWN immutability triggers;
      projectors, rebuilders and cursors bind to the module, so a
      simulated event cannot reach a real projector's rebuild — the real
      projector never reads that table (type-level isolation, not
      query-filter discipline).
    * `:domain` — the twin's domain (the host ledger inherits its own
      from `use Ash.Resource`; a generated module cannot).
    * `:clear_records_for_replay` — optional; required before running
      the log's `:replay` action (AshEvents raises without it).
    * `:simulation_base` — optional, `{module, use_opts}`: the base the
      twin is built on. By default the twin is a bare
      `use Ash.Resource` (AshPostgres, the two ledger extensions), so it
      has none of the host's tenancy, ownership, changes or policies. A
      host whose ledger stands on its own base passes that base here,
      and the twin is emitted as `use module, use_opts` — the same
      base the real ledger uses, so the host's grant union governs
      simulated events too. `use_opts` must bring the data layer and
      both `AshEvents.EventLog` and
      `AshDiscreteBusinessEvents.Ledger.Extension` (the twin refuses to
      compile otherwise); `:domain` is added when `use_opts` is a
      literal keyword list without one. Whatever the base adds (a
      `changes` block, policies) applies to the twin as written.

          use AshDiscreteBusinessEvents.Resources,
              {:ledger,
               repo: MyApp.Repo,
               table: "ledger_events",
               simulation_table: "ledger_simulation_events",
               domain: MyApp.BusinessEvents,
               simulation_base:
                 {MyApp.Platform.Resource,
                  extra_extensions: [AshEvents.EventLog,
                                     AshDiscreteBusinessEvents.Ledger.Extension]}}

  The ledger's only write path is `record` — locked per region
  (`RegionLockKeyGenerator`), chained per region (the emitted triggers),
  delivery-idempotent, append-only. The stock `:create` that AshEvents
  adds is removed by the macro's transformer: nothing writes this log
  unlocked. See `AshDiscreteBusinessEvents.Ledger`.
  """

  @ledger_required_opts [:repo, :table, :simulation_table]

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

  defmacro __using__({:ledger, opts}) do
    opts =
      Keyword.validate!(
        opts || [],
        @ledger_required_opts ++ [:domain, :clear_records_for_replay, :simulation_base]
      )

    # The base is AST spliced into the twin as written (its options are
    # evaluated where the twin is compiled), so it is taken out before the
    # rest of the options are expanded and persisted as data.
    {simulation_base, opts} = Keyword.pop(opts, :simulation_base)

    opts = Enum.map(opts, fn {key, value} -> {key, Macro.expand(value, __CALLER__)} end)

    missing =
      for key <- @ledger_required_opts, is_nil(Keyword.get(opts, key)), into: [], do: key

    unless missing == [] do
      names = Enum.map_join(missing, ", ", &":#{&1}")

      raise ArgumentError,
            "use AshDiscreteBusinessEvents.Resources, {:ledger, opts} requires #{names} " <>
              "(the chain/immutability triggers are named after the table, so " <>
              "the macro owns the ledger's postgres block)"
    end

    host_extensions = Module.get_attribute(__CALLER__.module, :extensions) || []

    unless AshEvents.EventLog in host_extensions do
      raise ArgumentError,
            "the :ledger macro requires AshEvents.EventLog in the host resource's " <>
              "`extensions:` (the ledger IS an AshEvents event log, §5.1)"
    end

    unless AshDiscreteBusinessEvents.Ledger.Extension in host_extensions do
      raise ArgumentError,
            "the :ledger macro requires AshDiscreteBusinessEvents.Ledger.Extension in the " <>
              "host resource's `extensions:` (its transformer builds the ledger's " <>
              "business-event columns, actions and triggers)"
    end

    simulation_table = Keyword.fetch!(opts, :simulation_table)
    domain = opts[:domain]
    clear_records_for_replay = opts[:clear_records_for_replay]

    twin_module = Module.concat(__CALLER__.module, SimulationEvent)
    twin_host_name = to_string(__CALLER__.module)

    # The event_log section MUST be present before ash_events' own
    # transformers run (they read these options to build the base
    # columns), so it is emitted statically here; only
    # clear_records_for_replay is optional, spliced as a literal AST node
    # (this is a macro — unquote is available).
    clear_fragment =
      if clear_records_for_replay do
        [{:clear_records_for_replay, [], [clear_records_for_replay]}]
      else
        []
      end

    event_log_section =
      quote do
        event_log do
          primary_key_type(Ash.Type.UUIDv7)
          record_id_type(:string)
          advisory_lock_key_generator(AshDiscreteBusinessEvents.Ledger.RegionLockKeyGenerator)
          public_fields(:all)
          unquote_splicing(clear_fragment)
        end
      end

    host_quote =
      quote location: :keep do
        unquote(event_log_section)

        # The ledger's builder transformer reads everything from here.
        @persist {:bizev_ledger, unquote(Macro.escape(opts))}
      end

    twin_use = twin_use(simulation_base, domain, __CALLER__)

    twin_opts =
      Keyword.merge(opts, simulation?: true)
      |> Keyword.put(:table, simulation_table)

    twin_moduledoc = """
    The simulation twin of #{twin_host_name} — emitted by the same
    `:ledger` macro declaration (§5.6, SIM-NAMESPACE-ISOLATION).

    Same columns, same locked-and-chained record path, own table
    (#{simulation_table}), own per-region chains. Every row carries
    `simulated: true` and a required `simulation_run` label. Projectors,
    rebuilders, cursors and chains bind to the MODULE: a simulated event
    cannot reach a real projector's rebuild because the real projector
    never reads this table. Isolation is type-level, not query-filter
    discipline — "every query must remember to filter" has no query to
    remember.
    """

    twin =
      quote location: :keep do
        @moduledoc unquote(twin_moduledoc)

        unquote(twin_use)

        AshDiscreteBusinessEvents.Resources.__verify_twin_extensions__!(__MODULE__)

        unquote(event_log_section)

        @persist {:bizev_ledger, unquote(Macro.escape(twin_opts))}
      end

    quote location: :keep do
      unquote(host_quote)

      defmodule unquote(twin_module) do
        unquote(twin)
      end
    end
  end

  defmacro __using__(:mapping_version) do
    quote location: :keep do
      # ── Versioned mapping artifacts (§5.3, the snapshot lifecycle) ──────
      # One row per compiled mapping declaration, content-addressed: the
      # hash IS the identity (declared operators in DECLARATION ORDER are
      # its input — ora-3 §13.3). The lifecycle is draft → validate →
      # activate; `validate` re-runs the compiler's structural checks over
      # the STORED artifact; `activate` freezes (and supersedes the name's
      # previous active — one active version per mapping name).
      # Content is immutable after draft: a changed declaration mints a
      # new version, never a rewrite.
      attributes do
        uuid_primary_key :id

        attribute :mapping_name, :string do
          allow_nil? false
          public? true
          constraints max_length: 256

          description "The declared mapping's name — the ledger's mapping_name provenance pointer, and the event kind the rule emits."
        end

        attribute :version_hash, :string do
          allow_nil? false
          public? true
          constraints max_length: 8

          description "The content hash (8 hex chars of the artifact's SHA-256) — the ledger's mapping_version_hash provenance pointer, and half of this row's identity."
        end

        attribute :source_name, :atom do
          allow_nil? false
          public? true
          description "The declared source the rule reads — first half of the source tuple."
        end

        attribute :stream_name, :atom do
          allow_nil? false
          public? true
          description "The declared stream the rule reads — second half of the source tuple."
        end

        attribute :status, :atom do
          allow_nil? false
          default :draft
          public? true
          constraints one_of: [:draft, :validated, :active]

          description "The lifecycle: draft → validate (compiler checks re-run over the stored artifact) → activate (freeze; supersedes). Content never changes after draft."
        end

        attribute :artifact, :map do
          allow_nil? false
          public? true

          description "The canonical artifact: name, source, and the operators in declaration order — the hashed form, stored as replayable data. Provenance on a ledger row points HERE, not at a code revision."
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      identities do
        identity :unique_name_hash, [:mapping_name, :version_hash]
      end

      actions do
        defaults [:read]

        read :by_name_and_hash do
          get? true
          argument :mapping_name, :string, allow_nil?: false
          argument :version_hash, :string, allow_nil?: false
          prepare {AshDiscreteBusinessEvents.MappingVersion.Preparations.ByNameAndHash, []}
        end

        read :active do
          get? true
          argument :mapping_name, :string, allow_nil?: false
          prepare {AshDiscreteBusinessEvents.MappingVersion.Preparations.Active, []}
        end

        create :draft do
          description "Records a freshly compiled declaration as a draft version. Content is frozen from here — changes mint new versions."
          accept [:mapping_name, :version_hash, :source_name, :stream_name, :artifact]
        end

        update :validate do
          description "Re-runs the compiler's structural checks over the STORED artifact; a draft that lost nothing becomes :validated."

          # The stored-artifact check is opaque Elixir over a map attribute —
          # not expressible as a database expression, so the action cannot
          # be atomic.
          require_atomic? false

          accept []
          validate attribute_equals(:status, :draft)
          change {AshDiscreteBusinessEvents.MappingVersion.Changes.ValidateStoredArtifact, []}
          change set_attribute(:status, :validated)
        end

        update :activate do
          description """
          Freezes a validated version as the mapping's active one, superseding the
          name's previous active (demoted to :validated — activation is the pointer
          move, history is never rewritten). The ledger's provenance joins
          mapping_name + mapping_version_hash to THIS row.
          """

          # The pointer move reads and demotes OTHER rows (the name's
          # previous active) inside the action's transaction.
          require_atomic? false

          accept []
          validate attribute_equals(:status, :validated)
          change {AshDiscreteBusinessEvents.MappingVersion.Changes.ActivateSuperseding, []}
          change set_attribute(:status, :active)
        end

        update :demote do
          description """
          INTERNAL: the superseded previous active steps back to :validated — its
          content stays exactly as proven; it is simply no longer the pointer's
          target.
          """

          accept []
          validate attribute_equals(:status, :active)
          change set_attribute(:status, :validated)
        end
      end

      code_interface do
        define :by_id, action: :read, get_by: [:id]

        define :by_name_and_hash,
          action: :by_name_and_hash,
          args: [:mapping_name, :version_hash],
          get?: true,
          not_found_error?: false

        define :active,
          action: :active,
          args: [:mapping_name],
          get?: true,
          not_found_error?: false

        define :validate_version, action: :validate
        define :activate_version, action: :activate
      end
    end
  end

  defmacro __using__(other) do
    known = [":source_record", "{:ledger, opts}", ":mapping_version"]

    raise ArgumentError,
          "use AshDiscreteBusinessEvents.Resources expects :source_record, {:ledger, opts} " <>
            "or :mapping_version, got: #{inspect(other)} (known: #{inspect(known)})"
  end

  @twin_extensions [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  # The twin's `use` line. Without a host base: a bare Ash resource with the
  # two ledger extensions. With one: the host's base and its options, as
  # written, plus the twin's domain when the options are a literal keyword
  # list that does not name one.
  defp twin_use(nil, domain, _caller) do
    use_opts =
      [data_layer: AshPostgres.DataLayer, extensions: @twin_extensions]
      |> then(fn base -> if domain, do: Keyword.put(base, :domain, domain), else: base end)

    quote do
      use Ash.Resource, unquote(Macro.escape(use_opts))
    end
  end

  defp twin_use({base, use_opts}, domain, caller) do
    base = Macro.expand(base, caller)

    unless is_atom(base) do
      raise ArgumentError,
            ":simulation_base must be {module, use_opts}, got a base of #{Macro.to_string(base)}"
    end

    use_opts =
      if domain && Keyword.keyword?(use_opts) && not Keyword.has_key?(use_opts, :domain),
        do: Keyword.put(use_opts, :domain, domain),
        else: use_opts

    quote do
      use unquote(base), unquote(use_opts)
    end
  end

  defp twin_use(other, _domain, _caller) do
    raise ArgumentError,
          ":simulation_base must be {module, use_opts}, got: #{Macro.to_string(other)}"
  end

  @doc false
  # Runs in the twin's module body, after its `use` line: a host base that
  # does not bring both ledger extensions would compile a twin without
  # `record`, chains or the `simulated` columns. Refuse instead.
  @spec __verify_twin_extensions__!(module()) :: :ok
  def __verify_twin_extensions__!(module) do
    extensions = Module.get_attribute(module, :extensions) || []

    case Enum.reject(@twin_extensions, &(&1 in extensions)) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "the simulation twin #{inspect(module)} is missing #{inspect(missing)}: a " <>
                ":simulation_base must bring AshEvents.EventLog and " <>
                "AshDiscreteBusinessEvents.Ledger.Extension (the twin IS a ledger)"
    end
  end
end
