# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Projections do
  @moduledoc """
  The projector story (design §5.1): ash_events_projections' declarative
  projectors drain the ledger **unchanged** — `project "<kind>", fn event
  -> ops end` — because the ledger IS an AshEvents log: the event kind
  rides the log's `action`, the subject's external id rides `record_id`,
  and the drained event is the FULL §1.4 row (region, occurred_at,
  observed_at, supersedes_event_id, provenance, sequence, data).

      defmodule MyApp.Projections.PipelineHistoryProjector do
        use AshDiscreteBusinessEvents.Projections,
          name: "pipeline_history_v1",
          event_log: MyApp.Platform.Ledger,
          projection_resource: MyApp.Projections.PipelineHistory

        grain fn event -> %{region: event.region, subject: event.record_id} end

        project "opportunity.stage_changed", fn event ->
          [{:set, :stage, event.data["to_stage"]}]
        end
      end

  `use` is a thin wrapper over `AshEvents.Projections.Projector` — the
  `project/2` (kind-only, any subject) and `grain/1` DSL pass through
  untouched — plus two things:

    * a compile-time check that the `event_log:` is a BIZEV ledger (it
      must expose the region-scoped `:feed` read), and
    * a generated `drain/2` — the **region-scoped** drain the host calls
      (or its job template calls; `AshDiscreteBusinessEvents.RunContext`
      threads the run).

  ## Why the package owns the drain (the §5.1 ruling, restated where it
  bites)

  The engine's own `AshEvents.Projections.Server` cannot drain this
  ledger, for two structural reasons — neither cosmetic:

    1. **It scans by global id.** `WHERE id > checkpoint ORDER BY id` is a
       cross-region merge by construction (§6): two regions' events
       interleave in one cursor, and a projector consuming them is
       consuming a dataset that does not exist. The ledger's sanctioned
       consumer cursor is the per-region commit-order `feed` — sequence
       order is commit order per region (the lock's property), so a
       per-region checkpoint can never silently skip a row.
    2. **It selects the origin's columns** (`practice_id`, `user_id`) in
       its drain query — schema the BIZEV ledger does not carry and must
       not (the §1.4 row shape is frozen by contract tests).

  So the drain lives here (`AshDiscreteBusinessEvents.Projections.Drain`),
  over the feed, reusing the engine's generic machinery wholesale: the
  Projector DSL, the ProjectionResource actions (`upsert_grain`,
  `apply_projection_ops`), the `Checkpoint`, and the `DeadLetter`. A
  projection target is an ordinary `AshEvents.Projections.ProjectionResource`
  — declare `temporal` on it and the projector's writes become periods
  (design §4: canonical projections ARE temporal, host-side).

  ## Temporal projections

  When the projection resource declares `temporal`, the drain writes
  **as of the event's `occurred_at`** — the source's truth time, never
  the drain's clock. A late arrival reopens the period at the instant the
  truth changed; a correction (an event with `supersedes_event_id` set)
  restates as a new period and the original is never rewritten. Replay
  re-derives the same periods in feed order — the equivalence property
  BIZEV-8's gate pins.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      event_log = Keyword.fetch!(opts, :event_log)

      unless Ash.Resource.Info.action(event_log, :feed) do
        raise ArgumentError,
              "#{inspect(event_log)} is not a BIZEV ledger — projectors drain the " <>
                "per-region commit-order feed, and this resource has no `:feed` read. " <>
                "Declare the ledger with `use AshDiscreteBusinessEvents.Resources, " <>
                "{:ledger, opts}` (§5.1)."
      end

      use AshEvents.Projections.Projector,
        name: Keyword.fetch!(opts, :name),
        event_log: event_log,
        projection_resource: Keyword.fetch!(opts, :projection_resource)

      # The package's region-scoped drain, bound to this projector. The
      # engine's Server is deliberately not started over the ledger — see
      # this module's moduledoc for the ruling.
      @doc """
      Drains this region's commit-order feed through the projector:
      processes every event after the per-(projector, region) checkpoint,
      in sequence order, atomically per event (ops + checkpoint advance
      commit together; a failure routes to the DeadLetter and the
      projector keeps flowing). Returns the number of events processed.

      Idempotent: the checkpoint is the cursor. Call again (or from the
      job template on every run) — already-drained events are skipped.
      """
      @spec drain(atom(), keyword()) :: non_neg_integer()
      def drain(region, opts \\ []) do
        AshDiscreteBusinessEvents.Projections.Drain.drain(__MODULE__, region, opts)
      end

      @doc """
      Drains one SIMULATION RUN — from the ledger's SimulationEvent twin,
      never the real log — through this projector, under the
      `sim:`-prefixed checkpoint namespace (SIM-NAMESPACE-ISOLATION
      AC-2): a simulation drain's cursor can never alias a real drain's
      on the same projector and region, and two simulation runs never
      share one. The projection target is the host's choice (what-if
      analyses typically target a separate projection resource).
      """
      @spec drain_simulation(String.t(), atom(), keyword()) :: non_neg_integer()
      def drain_simulation(simulation_run, region, opts \\ []) do
        AshDiscreteBusinessEvents.Projections.Drain.simulation(
          __MODULE__,
          simulation_run,
          region,
          opts
        )
      end
    end
  end
end
