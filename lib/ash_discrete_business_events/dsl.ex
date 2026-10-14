# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl do
  @moduledoc """
  The `business_events` DSL section: source declarations (the adapter
  boundary) and raw → canonical mapping declarations.

  The vocabulary is deliberately closed and schema-verified — a typo is a
  compile error, not a silently-ignored option. The `mapping` body's
  operator entities land in BIZEV-5; the entity exists now so the surface
  BIZEV-3/4/5 build on is frozen by this slice's tests.
  """

  @auth %Spark.Dsl.Entity{
    name: :auth,
    describe: """
    Declares where authentication for this source lives.

    ADR 0011's ruling, restated where it bites: Nango (or whatever the
    host uses) sits strictly at the *auth edge* — it yields tokens. The
    connection id is never an action argument, and no credential ever
    becomes DSL data here: this declaration names the strategy and the
    provider, the tokens stay with the host's secret machinery.
    """,
    examples: [
      "auth :nango, provider: \"salesforce\""
    ],
    target: AshDiscreteBusinessEvents.Dsl.Source.Auth,
    args: [:strategy],
    schema: [
      strategy: [
        type: :atom,
        doc: "The auth strategy — today `:nango` (ADR 0011: auth edge only)."
      ],
      provider: [
        type: :string,
        doc: "The provider identifier at the auth edge (e.g. `\"salesforce\"`)."
      ]
    ]
  }

  @stream %Spark.Dsl.Entity{
    name: :stream,
    describe: """
    Declares one stream within a source — a unit of landing with its own
    cursor, its own identity namespace, and its own place in the
    SourceRecord identity tuple (`source, stream, external_id, region`).

    Stream-in-the-identity is structural (the E1 known gap, fixed by
    design §1.3): two streams landing the same external id produce two
    distinct records, and no projector-side filtering is needed to tell
    them apart.
    """,
    examples: [
      """
      stream :opportunity do
        select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
      end
      """
    ],
    target: AshDiscreteBusinessEvents.Dsl.Source.Stream,
    args: [:name],
    schema: [
      name: [
        type: :atom,
        doc: "The stream name — the second element of the SourceRecord identity tuple."
      ],
      select: [
        type: :string,
        doc:
          "The adapter's selection declaration (for Bulk API 2.0, the SOQL query). " <>
            "Adapter-dependent; the Salesforce adapter (BIZEV-7) requires it."
      ]
    ]
  }

  @source %Spark.Dsl.Entity{
    name: :source,
    describe: """
    Declares an external source at the adapter boundary.

    Declarations only — execution lives in the job templates (BIZEV-6/7).
    What a source declaration pins today: which adapter serves it, where
    auth lives, what the cursor strategy is, which region it admits into,
    and its streams. Region is required and first-class (§6): admission
    targets, hash chains, commit-order sequences and feed cursors are all
    per-region, so a source without a region has no honest place to land.
    """,
    examples: [
      """
      source :salesforce do
        adapter AshDiscreteBusinessEvents.Adapters.SalesforceBulk20
        auth :nango, provider: "salesforce"
        cursor :system_modstamp
        region :us
        rate_budget [daily: 250_000]

        stream :opportunity do
          select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
        end
      end
      """
    ],
    target: AshDiscreteBusinessEvents.Dsl.Source,
    args: [:name],
    entities: [
      auth: [@auth],
      streams: [@stream]
    ],
    schema: [
      name: [
        type: :atom,
        doc: "The source name — the first element of the SourceRecord identity tuple."
      ],
      adapter: [
        type: {:behaviour, AshDiscreteBusinessEvents.Adapters.Adapter},
        doc:
          "The module implementing `AshDiscreteBusinessEvents.Adapters.Adapter` that " <>
            "serves this source. The behaviour's callbacks land with the first real " <>
            "adapter (BIZEV-7, Salesforce Bulk API 2.0); declaring the boundary now " <>
            "keeps declarations honest before implementations exist."
      ],
      cursor: [
        type: :atom,
        doc:
          "The cursor strategy — what advances the source's position (for Salesforce " <>
            "Bulk API 2.0, `:system_modstamp`). Cursors are data: they live on " <>
            "SourceRecord rows and sync-run records, never in job args (§2)."
      ],
      region: [
        type: :atom,
        required: true,
        doc:
          "The region this source admits into — the admission target and the feed " <>
            "partition. CA and US never merge silently (§6): per-region chains, " <>
            "locks, sequences and cursors all key off this."
      ],
      rate_budget: [
        type: :keyword_list,
        default: [],
        doc:
          "Advisory budget data surfaced to operators (e.g. `[daily: 250_000]` for " <>
            "the Salesforce daily API budget). The sync job FAILs visibly when a " <>
            "budget is exhausted — the feed pauses, it does not degrade (§7)."
      ]
    ]
  }

  @mapping %Spark.Dsl.Entity{
    name: :mapping,
    describe: """
    Declares a raw → canonical mapping: one event kind's rule for turning
    a SourceRecord observation into a ledger event.

    Every mapping declaration compiles to a content-hashed, versioned
    artifact (draft → validate → activate — the ash_decisions snapshot
    pattern), and the hash rides every ledger row the rule produces as
    provenance, so the mapping that produced any event is
    reconstructable from the row alone. The hash covers the operators in
    DECLARATION ORDER (ora-3 §13.3): the order of the rules is part of
    the rule.

    The body's vocabulary is closed (§5.3, the ash_strangler shape —
    deterministic and provenance-carrying, forward-only, replay-checked):
    `map`, `decode`, `coalesce`, `concat`, `constant`, and
    `unmapped_because` (refusal-by-name). Redundant operators are refused
    BY NAME at compile time; every mapping must extract `occurred_at`
    (source truth time) from the payload — the occurred-vs-observed
    discipline is compiler-enforced, not convention.
    """,
    examples: [
      """
      mapping :opportunity_stage_changed do
        source {:salesforce, :opportunity}

        map :stage, from: "StageName", type: :string
        map :amount, from: "Amount", type: :integer
        map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec

        decode :stage_bucket, from: "StageName",
          cases: %{"Prospecting" => "early", "Negotiation" => "late"}

        coalesce :close_date, from: ["CloseDate", "ExpectedCloseDate"]
        concat :label, from: ["Name", "StageName"], separator: " / "
        constant :source_system, value: "salesforce"

        unmapped_because :owner_email, "PII — kept out of canonical events (§9.5)"
      end
      """,
      """
      # blockless form — `source` as a keyword option. Note: a keyword list
      # before a do-block parses as a third macro argument, which Spark
      # entity macros cannot receive, so `source: {...}` and a block cannot
      # combine in one declaration (Elixir grammar, not a choice).
      mapping :opportunity_stage_changed, source: {:salesforce, :opportunity}
      """
    ],
    target: AshDiscreteBusinessEvents.Dsl.Mapping,
    args: [:name],
    entities: [
      ops: [
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.map(),
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.decode(),
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.coalesce(),
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.concat(),
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.constant(),
        AshDiscreteBusinessEvents.Dsl.Mapping.Ops.unmapped_because()
      ]
    ],
    schema: [
      name: [
        type: :atom,
        doc:
          "The mapping name — the `mapping_name` provenance pointer on every ledger " <>
            "row the rule produces, and the event kind the rule emits."
      ],
      source: [
        type: {:tuple, [:atom, :atom]},
        required: true,
        doc:
          "The `{source_name, stream_name}` this mapping reads from. Both halves " <>
            "must name a declared source and stream (compiler-verified)."
      ],
      classify_with: [
        type: :atom,
        doc:
          "Optional: a module implementing `AshDiscreteBusinessEvents.Mappings.Classifier` " <>
            "— the classification seam (§5.3). An ash_decisions DMN table behind this " <>
            "behaviour is the host's wiring; the package ships the seam and a behaviour, " <>
            "never the dependency. It may emit, override the event kind, or skip with a " <>
            "reason."
      ]
    ]
  }

  @business_events %Spark.Dsl.Section{
    name: :business_events,
    describe: """
    Declares the sources, streams and mappings this host serves — the
    adapter boundary and the raw → canonical rules, as data.

    Sections in play: `source` (with nested `auth` and `stream`) and
    `mapping` (one per event kind). Two resource-macro entry points —
    `use AshDiscreteBusinessEvents.Resources, :source_record` / `:ledger` —
    instantiate the resources on the host's own base; see
    `AshDiscreteBusinessEvents.Resources`.
    """,
    examples: [
      """
      business_events do
        source :salesforce do
          adapter AshDiscreteBusinessEvents.Adapters.SalesforceBulk20
          auth :nango, provider: "salesforce"
          cursor :system_modstamp
          region :us
          rate_budget [daily: 250_000]

          stream :opportunity do
            select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
          end
        end

        # Block form — hosts copy this example first, so it must compile
        # as shown. (ora-3 §13: a keyword list before a do-block parses as
        # a third macro argument, which Spark entity macros cannot
        # receive — the combined `mapping :name, source: {...} do ... end`
        # form does not compile.)
        mapping :opportunity_stage_changed do
          source {:salesforce, :opportunity}
          # closed operator vocabulary, §5.3
        end
      end
      """
    ],
    entities: [
      @source,
      @mapping
    ]
  }

  @doc false
  def business_events, do: @business_events
end
