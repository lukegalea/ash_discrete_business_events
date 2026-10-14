# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Projections.Drain do
  @moduledoc """
  The region-scoped projector drain — the piece of the engine this
  package owns, because the engine's Server cannot honestly drain this
  ledger (§6 + the origin's columns; the ruling lives on the
  `AshDiscreteBusinessEvents.Projections` moduledoc).

  Everything generic is the engine's, reused wholesale:

    * the Projector DSL's handlers (`project/2` kind routing, arity-1 and
      arity-2 handlers, `:skip`), and its grain semantics;
    * the ProjectionResource's `:upsert_grain` and `:apply_projection_ops`
      actions (the ops vocabulary: `{:increment, f, n}`, `{:decrement, f,
      n}`, `{:set, f, v}`, `{:max, f, v}`);
    * the `Checkpoint` (keyed per projector AND region —
      `"<name>.<region>"` — because two regions sharing a cursor would be
      the silent merge) and the `DeadLetter` (a poisoned event is isolated
      and the projector keeps flowing — silence is how a broken pipeline
      disappears).

  Everything ledger-specific is the §1.4 row: the drained event IS the
  ledger row, handlers see the whole truth-time shape, and — on temporal
  projection resources — every write runs `as_of event.occurred_at`, so
  late arrivals and corrections reopen periods at the instant the truth
  changed, never at the drain's clock (§4; the replay-equivalence gate
  stands on this).
  """

  alias AshEvents.Projections.Checkpoint
  alias AshEvents.Projections.Config
  alias AshEvents.Projections.DeadLetter

  require Ash.Expr

  @batch_limit 200

  @doc """
  Drains one region's feed through the projector until the feed is
  exhausted: every event after the per-(projector, region) checkpoint, in
  sequence order. Returns the number of events processed.
  """
  @spec drain(module(), atom(), keyword()) :: non_neg_integer()
  def drain(projector, region, opts \\ []) when is_atom(region) do
    event_log = event_log(projector, opts)
    checkpoint = checkpoint_for(projector, region, opts)
    after_sequence = checkpoint.last_seen_event_id || 0

    events =
      event_log
      |> Ash.Query.for_read(:feed, %{region: region, after_sequence: after_sequence})
      |> filter_sim_run(event_log, projector, opts)
      |> Ash.Query.limit(Keyword.get(opts, :limit, @batch_limit))
      |> Ash.read!(authorize?: false)

    Enum.each(events, &process_event(projector, event_log, &1, opts))

    length(events) + drained_after?(projector, region, opts, length(events))
  end

  @doc """
  Drains one SIMULATION RUN's feed — from the ledger's `SimulationEvent`
  twin, never the real log — through the projector, with checkpoints
  namespaced `sim:<name>.<region>:<run>` (SIM-NAMESPACE-ISOLATION AC-2):
  a simulation drain's cursor can never alias, satisfy, or be satisfied
  by a real drain's checkpoint on the same projector and region, and two
  simulation runs never share one either.
  """
  @spec simulation(module(), String.t(), atom(), keyword()) :: non_neg_integer()
  def simulation(projector, simulation_run, region, opts \\ [])
      when is_binary(simulation_run) and is_atom(region) do
    twin = simulation_event_log(projector)

    drain(
      projector,
      region,
      Keyword.merge(opts, simulation_run: simulation_run, event_log: twin)
    )
  end

  @doc "The SimulationEvent twin of the projector's event log."
  @spec simulation_event_log(module()) :: module()
  def simulation_event_log(projector) do
    Module.concat(projector.__event_log__(), "SimulationEvent")
  end

  defp event_log(projector, opts) do
    Keyword.get(opts, :event_log, projector.__event_log__())
  end

  # One simulation run's feed is ITS OWN events: the twin's table holds
  # every run, so the drain filters on the run label the rows carry.
  defp filter_sim_run(query, event_log, projector, opts) do
    case Keyword.get(opts, :simulation_run) do
      nil ->
        query

      run ->
        if event_log == simulation_event_log(projector) do
          Ash.Query.do_filter(query, Ash.Expr.expr(simulation_run == ^run))
        else
          query
        end
    end
  end

  # A full batch means the feed may not be exhausted yet — keep draining.
  defp drained_after?(_projector, _region, _opts, count) when count < @batch_limit, do: 0

  defp drained_after?(projector, region, opts, _count) do
    case drain(projector, region, opts) do
      0 -> 0
      more -> more
    end
  end

  @doc "The per-(projector, region) checkpoint's name — two regions never share a cursor."
  @spec checkpoint_name(module(), atom()) :: String.t()
  def checkpoint_name(projector, region), do: checkpoint_name(projector, region, [])

  @doc """
  The checkpoint's name, with the SIM-NAMESPACE-ISOLATION contract:
  real drains key `<name>.<region>`; a simulation drain keys
  `sim:<name>.<region>:<run>` — the `sim:` prefix plus the run label
  make aliasing with a real checkpoint (or another simulation run)
  structurally impossible, not a filter discipline. `sim:` is a
  RESERVED prefix for real projector names.
  """
  @spec checkpoint_name(module(), atom(), keyword()) :: String.t()
  def checkpoint_name(projector, region, opts) do
    case Keyword.get(opts, :simulation_run) do
      nil -> "#{projector.__projector_name__()}.#{region}"
      run -> "sim:#{projector.__projector_name__()}.#{region}:#{run}"
    end
  end

  # Per-event transaction: ops + checkpoint advance commit atomically. A
  # handler that raises rolls back and routes the event to the DeadLetter
  # in a fresh transaction, then the checkpoint advances past it — the
  # projector keeps flowing (the engine's policy, inherited verbatim).
  defp process_event(projector, event_log, event, opts) do
    fn ->
      apply_event(projector, event)
      checkpoint = checkpoint_for(projector, event.region, opts)
      Checkpoint.advance(checkpoint, event.sequence)
    end
    |> Config.repo().transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> handle_failure(projector, event_log, event, reason, [])
    end
  rescue
    error -> handle_failure(projector, event_log, event, error, __STACKTRACE__)
  end

  defp apply_event(projector, event) do
    resource = projector.__projection_resource__()

    with grain_key when not is_nil(grain_key) <- projector.__grain__().(event) do
      apply_grain_ops(projector, event, resource, grain_key)
    end
  end

  # Stateful (arity-2): the grain row loads FIRST — the handler sees the
  # row as the previous event left it. Stateless: the handler decides
  # before any DB hit.
  defp apply_grain_ops(projector, event, resource, grain_key) do
    if projector.needs_current_state?(event) do
      row = get_or_upsert_grain(resource, grain_key, event)

      case projector.handle_event(event, row) do
        {:ok, ops} when ops != [] -> apply_ops!(resource, row, ops, event)
        _ -> :ok
      end
    else
      case projector.handle_event(event) do
        {:ok, ops} when ops != [] ->
          row = get_or_upsert_grain(resource, grain_key, event)
          apply_ops!(resource, row, ops, event)

        _ ->
          :ok
      end
    end
  end

  # The grain row: read as of the event's truth time first (a serial drain
  # needs no lock), create — also as of truth time — when absent. On a
  # temporal resource the FIRST period opens at the truth instant, not at
  # the drain's clock.
  defp get_or_upsert_grain(resource, grain_key, event) do
    existing =
      grain_query(resource, grain_key)
      |> Ash.Query.as_of(as_of_for(resource, event))
      |> Ash.read_one(authorize?: false)

    case existing do
      {:ok, %{} = row} ->
        row

      _ ->
        resource
        |> Ash.Changeset.for_create(:upsert_grain, Map.new(grain_key))
        |> apply_as_of(resource, event)
        |> Ash.create!(authorize?: false)
    end
  end

  defp grain_query(resource, grain_key) do
    Enum.reduce(grain_key, resource, fn {field, value}, query ->
      Ash.Query.do_filter(query, Ash.Expr.expr(^Ash.Expr.ref(field) == ^value))
    end)
  end

  defp apply_ops!(resource, row, ops, event) do
    row
    |> Ash.Changeset.for_update(:apply_projection_ops, %{ops: ops})
    |> apply_as_of(resource, event)
    |> Ash.update!(authorize?: false)
  end

  # Temporal projections write as of the EVENT's truth time (§4): the
  # period basis is when the truth changed, never when the drain ran.
  # Non-temporal stats tables are untouched — the engine's semantics.
  defp apply_as_of(changeset, resource, event) do
    if Ash.Resource.Info.temporal?(resource) do
      Ash.Changeset.as_of(changeset, event.occurred_at)
    else
      changeset
    end
  end

  defp as_of_for(resource, event) do
    if Ash.Resource.Info.temporal?(resource), do: event.occurred_at, else: nil
  end

  defp handle_failure(projector, event_log, event, error, stacktrace) do
    opts = event_log_opts(event_log, event, projector)
    name = checkpoint_name(projector, event.region, opts)

    Config.repo().transaction(fn ->
      DeadLetter.record_failure(%{
        projection_name: name,
        event_id: event.sequence,
        error_class: error_class(error),
        error_message: error_message(error),
        stacktrace: format_stacktrace(stacktrace),
        failed_at: DateTime.utc_now()
      })

      checkpoint = checkpoint_for(projector, event.region, opts)
      Checkpoint.advance(checkpoint, event.sequence)
    end)
  rescue
    e ->
      # The DLQ write itself failed — let it crash loudly rather than
      # silently swallowing the event; the next drain re-attempts it.
      reraise e, __STACKTRACE__
  end

  defp checkpoint_for(projector, region, opts) do
    {:ok, checkpoint} = Checkpoint.initialize(checkpoint_name(projector, region, opts))
    checkpoint
  end

  # The namespace opts for a drained event log: when it is the
  # SimulationEvent twin, the run label rides the event — the checkpoint
  # (and DLQ quarantine) names derive from the same label the rows carry.
  defp event_log_opts(event_log, event, projector) do
    if event_log == simulation_event_log(projector) do
      [simulation_run: event.simulation_run]
    else
      []
    end
  end

  defp error_class(%mod{}), do: inspect(mod)
  defp error_class(_), do: "Unknown"

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(other), do: inspect(other)

  defp format_stacktrace([]), do: nil
  defp format_stacktrace(stacktrace), do: Exception.format_stacktrace(stacktrace)
end
