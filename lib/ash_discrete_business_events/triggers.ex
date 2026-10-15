# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Triggers.Handler do
  @moduledoc """
  The host's BPMN-side adapter (ADR 0030's EventSource pattern): one
  callback, receiving the FULL ledger row — the event kind, the
  subject/correlation keys, `process_ref`, provenance and data. The
  host dispatches to its waiting process instances and deduplicates
  (the bridge is at-least-once).
  """

  @callback nudge(event :: Ash.Resource.record()) :: :ok | {:error, term()}
end

defmodule AshDiscreteBusinessEvents.Triggers do
  @moduledoc """
  The BPMN trigger bridge (design §5.2) — ADR 0030's EventSource adapter
  pattern, with the audit trigger's division of labor: **nudge on
  append + sweep for completeness**. BPMN instances waiting on external
  business events (opportunity closed → fulfillment process) are nudged
  when a ledger event appends; the sweep re-dispatches anything the
  nudge missed, so dispatch is complete without coupling the ledger's
  write path to the process engine's health.

  **No ash_bpmn dependency**: hosts wire the adapter — a module
  implementing the `Handler` behaviour:

      config :ash_discrete_business_events, :trigger_handler,
        MyApp.Bpmn.EventSource

      defmodule MyApp.Bpmn.EventSource do
        @behaviour AshDiscreteBusinessEvents.Triggers.Handler

        def nudge(event) do
          # event is the full ledger row: the event kind in `action`,
          # subject_*, process_ref, provenance, data …
          MyApp.Bpmn.Runtime.dispatch(event.action, event)
        end
      end

  ## The contract

    * **Nudge on append, best-effort**: after a fresh append commits,
      the configured handler's `nudge/1` runs; a failure is logged and
      swallowed — the record stands, dispatch is the sweep's job.
      Simulated rows never nudge (SIM-NAMESPACE-ISOLATION: synthetic
      events never reach the real machinery).
    * **Sweep for completeness**: `sweep/3` walks the region's
      commit-order feed from the handler's dispatch cursor (an engine
      checkpoint keyed `triggers:<handler>.<region>`), nudging every
      event and advancing per event. At-least-once: a failed nudge
      leaves the cursor standing and the next sweep retries — handlers
      MUST be idempotent on the BPMN side (dispatch correlates by the
      event's subject/process_ref, and BPMN signal delivery
      deduplicates).
    * Delivery-collapsed retries (the same `delivery_key` recorded
      twice) nudge only on the fresh append — the collapsed path is a
      retry of an already-dispatched delivery.
  """

  require Logger

  @typedoc "The handler's dispatch cursor lives in the engine's checkpoint table."
  @type cursor :: AshEvents.Projections.Checkpoint.t() | nil

  @doc """
  The configured handler, or `nil` — no handler, no nudges, no sweep
  dispatch (the bridge is dormant and the ledger behaves exactly as
  BIZEV-4 shipped it).
  """
  @spec configured() :: module() | nil
  def configured do
    Application.get_env(:ash_discrete_business_events, :trigger_handler)
  end

  @doc """
  The append hook — called by the ledger's record path after a fresh
  append commits. Best-effort by contract: never fails the record, logs
  a missed nudge (the sweep recovers it), skips simulated rows and
  unconfigured hosts.
  """
  @spec after_append(record :: Ash.Resource.record()) :: :ok
  def after_append(record)

  def after_append(%{simulated: true}), do: :ok

  def after_append(record) do
    case configured() do
      nil ->
        :ok

      handler ->
        case handler.nudge(record) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[triggers] nudge missed for #{inspect(record.event_kind)} " <>
                "(#{record.subject_external_id}): #{inspect(reason)} — the sweep will re-dispatch"
            )

            :ok
        end
    end
  rescue
    e ->
      Logger.warning(
        "[triggers] nudge raised (the sweep will re-dispatch): #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  The completeness sweep (§5.2): walks `region`'s commit-order feed from
  the handler's dispatch cursor (an engine checkpoint keyed
  `triggers:<handler>.<region>`), nudging every event and advancing the
  cursor per event. Returns `{:ok, %{dispatched: n, cursor: seq}}`.

  At-least-once: a nudge failure (or a handler raise) STOPS the sweep at
  that event — the cursor stands at the last dispatch, the feed pauses,
  the next sweep retries it. Handlers must be idempotent on the BPMN
  side (dispatch correlates by subject/process_ref).

  Options: `:handler` (override; default the configured one),
  `:limit` (batch size, default 200 — full batches keep sweeping).
  """
  @spec sweep(ledger :: module(), region :: atom(), keyword()) ::
          {:ok, %{dispatched: non_neg_integer(), cursor: integer() | nil}}
  def sweep(ledger, region, opts \\ []) when is_atom(region) do
    handler =
      Keyword.get(opts, :handler) || configured() ||
        raise(
          "no trigger handler configured (config :ash_discrete_business_events, :trigger_handler) — the sweep has nothing to dispatch to"
        )

    do_sweep(ledger, handler, region, opts, 0)
  end

  @sweep_limit 200

  defp do_sweep(ledger, handler, region, opts, acc) do
    limit = Keyword.get(opts, :limit, @sweep_limit)
    {:ok, checkpoint} = AshEvents.Projections.Checkpoint.initialize(cursor_name(handler, region))
    after_sequence = checkpoint.last_seen_event_id || 0

    events =
      ledger
      |> Ash.Query.for_read(:feed, %{region: region, after_sequence: after_sequence})
      |> Ash.Query.limit(limit)
      |> Ash.read!(authorize?: false)

    case dispatch_batch(handler, region, events, 0) do
      {:ok, count, _cursor} when length(events) == limit ->
        case do_sweep(ledger, handler, region, opts, acc + count) do
          {:ok, %{dispatched: more, cursor: cursor}} ->
            {:ok, %{dispatched: acc + count + more, cursor: cursor}}
        end

      {:ok, count, _cursor} ->
        {:ok, cp} = AshEvents.Projections.Checkpoint.initialize(cursor_name(handler, region))
        {:ok, %{dispatched: acc + count, cursor: cp.last_seen_event_id}}
    end
  end

  # Per event: nudge; on :ok advance the dispatch cursor (the checkpoint
  # IS the dispatch position); on failure stop — the cursor stands at the
  # last dispatch, the next sweep retries from the failure.
  defp dispatch_batch(_handler, _region, [], n), do: {:ok, n, nil}

  defp dispatch_batch(handler, region, [event | rest], n) do
    case handler.nudge(event) do
      :ok ->
        {:ok, cp} = AshEvents.Projections.Checkpoint.initialize(cursor_name(handler, region))
        AshEvents.Projections.Checkpoint.advance(cp, event.sequence)
        dispatch_batch(handler, region, rest, n + 1)

      _ ->
        {:ok, n, :stopped}
    end
  end

  defp cursor_name(handler, region) do
    name = handler |> Module.split() |> Enum.join(".")
    "triggers:#{name}.#{region}"
  end
end
