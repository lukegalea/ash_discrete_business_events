# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Transformers.DefineLedger do
  @moduledoc """
  Builds the ledger's business-event surface from the `:ledger` macro's
  persisted options: the §1.4 columns (subject/actor descriptors, three
  clocks, context + provenance, `supersedes_event_id`, `delivery_key`,
  region + residency, lock-ordered `sequence`, chain hashes — plus
  `simulated`/`simulation_run` on the twin), the delivery identity, the
  read surface (region-scoped by construction, plus the commit-order
  feed), the locked `:append`/`:record` write path, the gated
  `:cross_region_read`, and the postgres block carrying the per-region
  chain and immutability triggers.

  Runs after AshEvents' own transformers (which supply the log's base
  columns and — removed here — the stock `:create`).
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshDiscreteBusinessEvents.Ledger.ChainSQL

  # Transformer ordering: everything this does must land after ash_events
  # added the log's base columns and actions (and the stock :create this
  # transformer removes).
  @impl true
  def after?(AshEvents.EventLog.Transformers.AddActions), do: true

  @impl true
  def after?(AshEvents.EventLog.Transformers.AddAttributes), do: true

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    case Spark.Dsl.Transformer.get_persisted(dsl, :bizev_ledger) do
      nil -> {:ok, dsl}
      opts -> {:ok, build(dsl, opts)}
    end
  end

  defp build(dsl, opts) do
    sim? = !!opts[:simulation?]
    module = Spark.Dsl.Transformer.get_persisted(dsl, :module)

    dsl
    |> add_attributes(sim?)
    |> add_delivery_identity()
    |> add_actions(module, sim?)
    |> add_code_interfaces()
    |> remove_stock_create()
    |> set_postgres(opts)
    |> unwrap()
  end

  # ── code interfaces ────────────────────────────────────────────────────

  defp add_code_interfaces(dsl) do
    interfaces = [
      [name: :record, action: :record],
      [name: :by_region, action: :by_region, args: [:region]],
      [name: :feed, action: :feed, args: [:region]],
      [
        name: :by_subject,
        action: :by_subject,
        args: [:region, :subject_external_id, {:optional, :subject_stream}]
      ],
      [name: :by_id, action: :by_id, args: [:id, :region], get?: true, not_found_error?: false],
      [name: :cross_region_read, action: :cross_region_read]
    ]

    Enum.reduce(interfaces, dsl, fn opts, dsl ->
      {:ok, interface} =
        Spark.Dsl.Transformer.build_entity(Ash.Resource.Dsl, [:code_interface], :define, opts)

      Spark.Dsl.Transformer.add_entity(dsl, [:code_interface], interface)
    end)
  end

  # ── attributes (§1.4's table, column by column) ────────────────────────

  defp add_attributes(dsl, sim?) do
    attrs =
      [
        {:region, :atom,
         allow_nil?: false,
         public?: true,
         description:
           "The region this event belongs to — the feed partition, its own chain, its own lock (§6). CA and US never merge silently."},
        {:residency_tag, :string,
         allow_nil?: false,
         public?: true,
         description:
           "The residency declaration admitted at land (ADR 0042) — carried onto the ledger row."},
        {:subject_type, :string,
         allow_nil?: false,
         public?: true,
         description:
           "What the event is about — a DESCRIPTOR, never a foreign key (ADR 0017: entity resolution is projection work, never done at record time)."},
        {:subject_external_id, :string,
         allow_nil?: false,
         public?: true,
         constraints: [max_length: 512],
         description:
           "The subject's external id — VendorPM Law 1: an idempotency key, never an identity. Also rides the log's record_id (the machinery's subject key)."},
        {:subject_stream, :atom,
         public?: true,
         description:
           "The stream the subject was observed in. Nil for streamless (webhook) events."},
        {:actor_type, :string,
         public?: true,
         description:
           "Who did it — verbatim external actor type. Resolution to internal people is projection work; recording stays pure and PII-minimal."},
        {:actor_external_id, :string,
         public?: true, description: "The actor's external id, verbatim."},
        {:actor_display, :string,
         public?: true, description: "The actor's display name as the source supplied it."},
        {:observed_at, :utc_datetime_usec,
         allow_nil?: false,
         default: &DateTime.utc_now/0,
         public?: true,
         description:
           "When WE learned of the event — knowledge time, the write's clock. Late arrival is ordinary; no column pretends otherwise."},
        {:context, :map,
         public?: true,
         description:
           "Why — structured, optional: reason codes and description fields the source supplies. The system-side why is PROVENANCE, which is data."},
        {:provenance, :map,
         allow_nil?: false,
         public?: true,
         description:
           "Per mapping rule, on every row: mapping_name, mapping_version_hash, source_record_id — the mapping that produced this event is reconstructable from the row alone (§5.3)."},
        {:supersedes_event_id, :uuid,
         public?: true,
         description:
           "Corrections are new events, never rewrites (§7): this row supersedes the event with that id. The original is never rewritten — chain integrity."},
        {:delivery_key, :string,
         public?: true,
         constraints: [max_length: 512],
         description:
           "Delivery-level idempotency: webhook retries collapse here, below source-level idempotency. The two layers answer different questions (§1.4)."},
        {:sequence, :integer,
         generated?: true,
         writable?: false,
         public?: true,
         description:
           "Commit order within the region: a bigserial made safe by the per-region advisory lock taken BEFORE insert (xact-scoped, same transaction). Within one region, sequence order IS commit order — the property a feed cursor needs. Caveats + the permanent measurement test: RegionLockKeyGenerator."},
        {:previous_hash, :string,
         generated?: true,
         writable?: false,
         public?: true,
         description: "The hash of the preceding event in this region's chain."},
        {:hash, :string,
         generated?: true,
         writable?: false,
         public?: true,
         description:
           "SHA-256 over this event's contents and previous_hash (per-region chain; ChainSQL holds the canonical form)."}
      ] ++
        if sim? do
          [
            {:simulated, :boolean,
             allow_nil?: false,
             default: true,
             public?: true,
             description:
               "Always true on the twin: a sim row is unmistakable by shape, not by a query remembering to check."},
            {:simulation_run, :string,
             allow_nil?: false,
             public?: true,
             description: "The simulation run's label — AC-3's unmistakable UI labeling."}
          ]
        else
          []
        end

    Enum.reduce(attrs, dsl, fn {name, type, opts}, dsl ->
      {:ok, dsl} = Builder.add_attribute(dsl, name, type, opts)
      dsl
    end)
  end

  defp add_delivery_identity(dsl) do
    {:ok, dsl} =
      Builder.add_identity(dsl, :unique_delivery, [:delivery_key, :region],
        description:
          "Delivery idempotency is PER REGION (a global delivery identity would be a silent region merge, §6); nil delivery keys stay distinct."
      )

    dsl
  end

  # ── actions ────────────────────────────────────────────────────────────

  defp add_actions(dsl, module, sim?) do
    dsl
    |> add_read_actions()
    |> add_append(sim?)
    |> add_record(module, sim?)
    |> add_cross_region_read(module)
  end

  defp add_read_actions(dsl) do
    dsl
    |> add_read(:read,
      primary?: true,
      # Keyset: AshEvents' replay streams the log through this read.
      pagination: pagination(),
      description:
        "MACHINERY-ONLY: the log's default read (AshEvents' replay scans through it, and a rebuild is cross-region by nature). Not in the code interface; every consumer-facing read is region-scoped, and the one gated exception is cross_region_read. Hosts gate this through their policies like everything else."
    )
    |> add_read(:by_region,
      description:
        "One region's events, in sequence order. Plain reads REQUIRE a region (§6): a query without one is a silent cross-region merge. The one gated exception is cross_region_read.",
      arguments: [arg(:region, :atom, allow_nil?: false)],
      preparations: [prep(AshDiscreteBusinessEvents.Ledger.Preparations.RegionScoped)],
      pagination: pagination()
    )
    |> add_read(:feed,
      description:
        "The commit-order feed: one region's events after a sequence high-water mark, in sequence order. sequence order is commit order per region (the lock's property), so a consumer's cursor can never silently skip a row.",
      arguments: [
        arg(:region, :atom, allow_nil?: false),
        arg(:after_sequence, :integer,
          allow_nil?: true,
          default: 0,
          description: "The consumer's high-water mark; the feed resumes strictly after it."
        )
      ],
      preparations: [prep(AshDiscreteBusinessEvents.Ledger.Preparations.Feed)],
      pagination: pagination()
    )
    |> add_read(:by_subject,
      description:
        "One region's events about one subject (and, when declared, one stream), in sequence order.",
      arguments: [
        arg(:region, :atom, allow_nil?: false),
        arg(:subject_external_id, :string, allow_nil?: false),
        arg(:subject_stream, :atom, allow_nil?: true)
      ],
      preparations: [prep(AshDiscreteBusinessEvents.Ledger.Preparations.BySubject)]
    )
    |> add_read(:by_id,
      get?: true,
      description:
        "One event by id AND region — even a point lookup states its jurisdiction (§6).",
      arguments: [
        arg(:id, :uuid, allow_nil?: false),
        arg(:region, :atom, allow_nil?: false)
      ],
      preparations: [prep(AshDiscreteBusinessEvents.Ledger.Preparations.ById)]
    )
    |> add_read(:cross_region_scan,
      description:
        "INTERNAL: scans across regions, for cross_region_read alone. Not exposed through the code interface; the operator action is the gate, and the disclosure rows it writes are the alarm.",
      arguments: [],
      preparations: []
    )
  end

  defp add_append(dsl, sim?) do
    accept =
      ~w(region residency_tag subject_type subject_external_id subject_stream actor_type
         actor_external_id actor_display occurred_at observed_at context provenance
         supersedes_event_id delivery_key data)a ++ if sim?, do: [:simulation_run], else: []

    {:ok, dsl} =
      Builder.add_action(dsl, :create, :append,
        description:
          "INTERNAL: the locked append — record's write path. Takes the per-region advisory xact lock (StampEvent), stamps the AshEvents machinery fields, and inserts; the chain trigger fires under the same lock. Not exposed through the code interface.",
        arguments: [
          arg(:event_kind, :atom, allow_nil?: false),
          arg(:subject_resource, :atom,
            allow_nil?: true,
            description: "Replay-routing target for the event kind; defaults to :\"bizev.event\"."
          )
        ],
        accept: accept,
        changes: [
          %Ash.Resource.Change{change: {AshDiscreteBusinessEvents.Ledger.Changes.StampEvent, []}}
        ]
      )

    dsl
  end

  defp add_record(dsl, module, sim?) do
    arguments =
      [
        arg(:event_kind, :atom, allow_nil?: false),
        arg(:region, :atom, allow_nil?: false),
        arg(:residency_tag, :string, allow_nil?: false),
        arg(:subject_type, :string, allow_nil?: false),
        arg(:subject_external_id, :string, allow_nil?: false),
        arg(:subject_stream, :atom, allow_nil?: true),
        arg(:actor_type, :string, allow_nil?: true),
        arg(:actor_external_id, :string, allow_nil?: true),
        arg(:actor_display, :string, allow_nil?: true),
        arg(:occurred_at, :utc_datetime_usec, allow_nil?: false),
        arg(:observed_at, :utc_datetime_usec, allow_nil?: true),
        arg(:context, :map, allow_nil?: true),
        arg(:provenance, :map, allow_nil?: false),
        arg(:supersedes_event_id, :uuid, allow_nil?: true),
        arg(:delivery_key, :string, allow_nil?: true),
        arg(:data, :map, allow_nil?: true, default: %{}),
        arg(:subject_resource, :atom, allow_nil?: true)
      ] ++
        if sim? do
          [arg(:simulation_run, :string, allow_nil?: false)]
        else
          []
        end

    {:ok, dsl} =
      Builder.add_action(dsl, :action, :record,
        description: """
        Record one canonical discrete business event — the ledger's ONLY write path (§5.1: the ledger's events are not side-effects of resource CRUD; rows are written directly, locked and chained).

        * Per-region advisory xact lock BEFORE insert → sequence order is commit order per region.
        * Per-region hash chain (trigger, same lock) → tamper-evident.
        * Delivery idempotency: a delivery_key this region has already recorded collapses to the existing row (webhook retries; below source-level idempotency, which is the raw layer's job).
        * Corrections are NEW rows with supersedes_event_id set — the original is never rewritten.
        """,
        returns: :struct,
        constraints: [instance_of: module],
        transaction?: true,
        arguments: arguments,
        run: {AshDiscreteBusinessEvents.Ledger.Record, []}
      )

    dsl
  end

  defp add_cross_region_read(dsl, module) do
    {:ok, dsl} =
      Builder.add_action(dsl, :action, :cross_region_read,
        description: """
        The ONE gated exception to region-scoped reads (§6): an operator investigation across two or more regions. Requires explicit region arguments, is gated by the host's policies, and records one DISCLOSURE row per queried region (event kind :"region.disclosure") — a cross-region total is shown WITH its jurisdictions, never without (ADR 0042's flow rule). Convenience has a door, but it's alarmed.
        """,
        returns: {:array, :struct},
        constraints: [items: [instance_of: module]],
        transaction?: true,
        arguments: [
          arg(:regions, {:array, :atom}, allow_nil?: false),
          arg(:purpose, :string, allow_nil?: false)
        ],
        run: {AshDiscreteBusinessEvents.Ledger.CrossRegionRead, []}
      )

    dsl
  end

  defp remove_stock_create(dsl) do
    Spark.Dsl.Transformer.remove_entity(dsl, [:actions], &(&1.name == :create))
  end

  # ── postgres: repo, table, chain + immutability triggers ───────────────

  defp set_postgres(dsl, opts) do
    table = opts[:table]
    repo = opts[:repo]

    statements =
      [
        {:bizev_chain_function, ChainSQL.chain_function_sql(table, "bizev_#{table}_chain_fn"),
         "DROP FUNCTION IF EXISTS bizev_#{table}_chain_fn() CASCADE;"},
        {:bizev_chain_trigger,
         ChainSQL.chain_trigger_sql(table, "bizev_#{table}_chain_fn", "bizev_#{table}_chain"),
         "DROP TRIGGER IF EXISTS bizev_#{table}_chain ON #{table};"},
        {:bizev_immutable_function, ChainSQL.immutability_function_sql(table),
         "DROP FUNCTION IF EXISTS bizev_#{table}_immutable_fn() CASCADE;"},
        {:bizev_immutable_trigger, ChainSQL.immutability_trigger_sql(table),
         "DROP TRIGGER IF EXISTS bizev_#{table}_immutable ON #{table};"}
      ]
      |> Enum.map(fn {name, up, down} ->
        {:ok, statement} =
          Spark.Dsl.Transformer.build_entity(
            AshPostgres.DataLayer,
            [:postgres, :custom_statements],
            :statement,
            name: name,
            up: up,
            down: down
          )

        statement
      end)

    dsl
    |> then(fn dsl ->
      # Validate against the section schema (fills defaults like
      # migrate?) and merge into whatever the DSL already carries — the
      # same shape Spark's own `__set_and_validate_options__` writes.
      section = Enum.find(AshPostgres.DataLayer.sections(), &(&1.name == :postgres))

      config = Map.get(dsl, [:postgres], Spark.Dsl.Extension.default_section_config())

      {:ok, validated} =
        Spark.Options.validate(
          Keyword.merge(Keyword.new(config[:opts] || []), table: table, repo: repo),
          section.schema
        )

      Map.put(dsl, [:postgres], %{config | opts: validated})
    end)
    |> then(fn dsl ->
      path = [:postgres, :custom_statements]

      config = Map.get(dsl, path, Spark.Dsl.Extension.default_section_config())

      Map.put(dsl, path, %{
        config
        | entities: List.wrap(config[:entities]) ++ statements
      })
    end)
  end

  # ── small builders ─────────────────────────────────────────────────────

  defp arg(name, type, opts) do
    {:ok, argument} = Builder.build_action_argument(name, type, opts)
    argument
  end

  defp prep(module) do
    {:ok, preparation} = Builder.build_preparation({module, []})
    preparation
  end

  defp pagination do
    {:ok, pagination} = Builder.build_pagination(keyset?: true, required?: false)
    pagination
  end

  defp add_read(dsl, name, opts) do
    {:ok, dsl} = Builder.add_action(dsl, :read, name, opts)
    dsl
  end

  defp unwrap(dsl), do: dsl
end
