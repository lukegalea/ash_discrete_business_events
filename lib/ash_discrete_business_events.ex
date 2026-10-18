# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents do
  @moduledoc """
  The canonical discrete business-event ledger for Ash.

  External SaaS history (Salesforce, Stripe, product databases) enters the
  platform through one typed boundary, in three layers:

    * **SourceRecord** — the raw-landing layer: the raw payload as observed,
      immutable, with *temporal version history* (append-only periods keyed
      by `(source, stream, external_id, region)`), cursor-as-data, and
      zone/residency admission checked on the land path.
    * **The Ledger** — a dedicated, append-only `AshEvents.EventLog` whose
      rows *are* canonical discrete business events: who/what/when/why,
      `occurred_at` vs `observed_at`, a commit-order `sequence` per region
      (advisory-xact-lock), a per-region hash chain, corrections-as-events
      via `supersedes_event_id`, and delivery-level idempotency.
    * **Mappings as data** — versioned, content-hashed declarations that
      turn a raw observation into a canonical event, recording provenance
      on every ledger row.

  The ledger is **not** temporal (create-only facts — corrections are new
  rows, never rewrites); the raw layer and host projections **are**. See
  the README for the full design summary and `docs/REVIEW.md` for the
  review checklist that guards these rulings.

  ## Usage

      defmodule MyApp.BusinessEvents do
        use AshDiscreteBusinessEvents, domains: [MyApp.BusinessEvents]

        business_events do
          source :salesforce do
            adapter MyApp.Adapters.SalesforceBulk20
            auth :nango, provider: "salesforce"
            cursor :system_modstamp
            region :us
            rate_budget [daily: 250_000]

            stream :opportunity do
              select "SELECT Id, Name, StageName, Amount, SystemModstamp, LastModifiedById FROM Opportunity"
            end
          end

          mapping :opportunity_stage_changed, source: {:salesforce, :opportunity} do
            map :stage, from: "StageName", type: :string
            map :amount, from: "Amount", type: :integer
            map :occurred_at, from: "SystemModstamp", type: :utc_datetime_usec

            constant :source_system, value: "salesforce"

            unmapped_because :owner_email, "PII — kept out of canonical events"
          end
        end
      end

  The mapping body's vocabulary is closed and schema-verified (a typo is
  a compile error): `map`, `decode`, `coalesce`, `concat`, `constant`,
  and `unmapped_because` — with redundancy refused by name, dangerous
  combos refused, and an `occurred_at` extraction compiler-enforced in
  every mapping. Each declaration compiles to a content-hashed artifact
  (`AshDiscreteBusinessEvents.Mappings.publish/3` records it as a
  `MappingVersion` — draft → validate → activate), the hash riding every
  ledger row the rule produces as provenance.

  Hosts instantiate the resources on their own base via the resource
  macros — `use AshDiscreteBusinessEvents.Resources, :source_record`,
  `:ledger`, and `:mapping_version` — **resource macros, not concrete
  modules**: Spark builds policies at the package's compile time, so
  concrete modules can't take host policy blocks; macros inherit the
  host's grant union natively. Landing external data is exactly the kind
  of action a tenant must be able to govern.

  ## Status

  BIZEV-2 froze the contracts (DSL surface, ledger row shape,
  SourceRecord identity tuple); BIZEV-3 delivered SourceRecord; BIZEV-4
  the ledger; BIZEV-5 (this slice) the mapping engine — rules as
  versioned, content-hashed data.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [AshDiscreteBusinessEvents.Extension]],
    opt_schema: [
      domains: [
        type: {:list, :atom},
        doc:
          "The host Ash domains this declaration serves. Recorded as data on the " <>
            "host module (read it back with `AshDiscreteBusinessEvents.Info.domains/1`); " <>
            "later slices use it for wiring and verification (the ledger macro binds " <>
            "generated resources to these domains)."
      ]
    ]

  # Runs in the host module when it declares `use AshDiscreteBusinessEvents`.
  # Spark validates the `use` options against `opt_schema` above before this
  # runs; we persist the accepted ones so `AshDiscreteBusinessEvents.Info`
  # can read them back (the `otp_app` pattern from `Spark.Dsl`).
  @doc """
  The SIM-NAMESPACE-ISOLATION labeling contract, executable (AC-3):
  groups a ledger's SimulationEvent twin rows by their `simulation_run`
  label, so any surface that lists event history can label simulated
  runs unmistakably — `simulated: true` plus the run label ride every
  twin row by shape, and this function is the supported read.

  Accepts the ledger resource OR its SimulationEvent twin directly.
  `opts` are passed to the read (default `authorize?: false`): a host
  whose twin stands on a multitenant base (`:simulation_base`) passes the
  `tenant:` (or an `actor:` with `authorize?: true`) to list one tenant's
  runs. Returns one map per run — `simulation_run`, `events`, `subjects`,
  `first_observed_at`, `last_observed_at` — sorted by run label.

  ## The contract (the ticket's "unmistakable in the UI", since the
  package ships no UI)

    * Simulated events live ONLY in the twin (`<Ledger>.SimulationEvent`)
      — a real-ledger read can never contain one, structurally.
    * Every twin row carries `simulated: true` and `simulation_run` —
      set at record time, not query time.
    * Any surface showing these rows renders the run label (and/or the
      literal word "simulated") — a row without a run label cannot come
      from the twin, and a row in the real ledger cannot be simulated.

  Real projector rebuilds never read the twin, so simulated events can
  never appear in a rebuilt state (AC-1), and simulation drains key
  their checkpoints `sim:<name>.<region>:<run>` — never aliasing a real
  drain's cursor (AC-2).
  """
  @spec simulation_runs(module(), keyword()) :: [
          %{
            required(:simulation_run) => String.t(),
            required(:events) => non_neg_integer(),
            required(:subjects) => non_neg_integer(),
            required(:first_observed_at) => DateTime.t() | nil,
            required(:last_observed_at) => DateTime.t() | nil
          }
        ]
  def simulation_runs(ledger_or_twin, opts \\ []) do
    twin = simulation_twin(ledger_or_twin)

    twin
    |> Ash.read!(Keyword.merge([authorize?: false], opts))
    |> Enum.group_by(& &1.simulation_run)
    |> Enum.map(fn {run, rows} ->
      observed = Enum.map(rows, & &1.occurred_at) |> Enum.sort(DateTime)

      %{
        simulation_run: run,
        events: length(rows),
        subjects: rows |> Enum.map(& &1.subject_external_id) |> Enum.uniq() |> length(),
        first_observed_at: List.first(observed),
        last_observed_at: List.last(observed)
      }
    end)
    |> Enum.sort_by(& &1.simulation_run)
  end

  defp simulation_twin(resource) do
    if Ash.Resource.Info.attribute(resource, :simulation_run) do
      resource
    else
      Module.concat(resource, "SimulationEvent")
    end
  end

  @doc false
  def handle_opts(opts) do
    domains = opts |> Keyword.get(:domains, []) |> Macro.escape()

    quote do
      @persist {:domains, unquote(domains)}
    end
  end
end
