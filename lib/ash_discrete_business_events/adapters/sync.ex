# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.Sync do
  @moduledoc """
  The sync job template — the shape BIZEV-7's adapter (and every later
  adapter) is driven by: resolve the conn at the auth edge, emit lineage
  START, fetch batches and land every record through the land action,
  emit lineage COMPLETE with facet-level counts — or FAIL, loudly, at
  budget exhaustion or any transport failure. **The feed pauses, it does
  not degrade**: a failed sync leaves the cursor where the last
  completed batch ended, and the next sync resumes strictly after it.

  Cursor state is DATA: the caller passes the water mark (`:cursor`) it
  keeps on its sync-run record, and the summary returns the cursor to
  store. Nothing cursor-shaped travels in job args.

  ## Options

    * `:source`, `:stream` — the declared `t:Dsl.Source.t/0` and its
      stream (from `AshDiscreteBusinessEvents.Info`).
    * `:source_record` — the host's SourceRecord resource.
    * `:cursor` — the resume water mark (a map keyed by the adapter's
      cursor field); `nil` syncs from the beginning (a fresh stream or a
      deliberate full re-sync).
    * `:fetched_at` — the observation instant stamped on landed records;
      defaults to now (the corpus import passes each run's manifest
      instant for determinism).
    * `:region`, `:residency_tag` — the admission target (default the
      source's region; tag defaults to the region's name).
    * `:lineage_job` — a `Lineage.job/2` descriptor; `nil` (tests) skips
      lineage emission.
    * `:max_batches` — safety cap on batches per run (default 100).
    * `:limit` — per-batch record cap handed to the adapter.
    * `:adapter`, `:auth_provider` — overrides (tests; otherwise the
      source's `adapter` and the configured auth edge).

  ## Returns

    * `{:ok, %{landed:, batches:, cursor:, api_calls_used:}}` — landed
      counts NEW periods (identical re-observations are temporal no-ops
      and don't count); `cursor` is the resume point to persist.
    * `{:error, term}` — the job failed visibly. `Adapters.BudgetExhausted`
      carries what the completed portion achieved (`landed`, `cursor`).
  """

  alias AshDiscreteBusinessEvents.Adapters.AuthProvider
  alias AshDiscreteBusinessEvents.Adapters.BudgetExhausted
  alias AshDiscreteBusinessEvents.Lineage

  @default_max_batches 100

  @spec run(keyword()) ::
          {:ok, %{landed: non_neg_integer(), batches: pos_integer(), cursor: map(),
                  api_calls_used: non_neg_integer()}}
          | {:error, term()}
  def run(opts) do
    source = Keyword.fetch!(opts, :source)
    stream = Keyword.fetch!(opts, :stream)
    source_record = Keyword.fetch!(opts, :source_record)
    adapter = Keyword.get(opts, :adapter, source.adapter)

    job = Keyword.get(opts, :lineage_job)
    run_id = Lineage.run_id(:operational)

    try do
      lineage_wrap(job, run_id, fn ->
        with {:ok, conn} <- resolve_conn(opts, source) do
          sync_loop(adapter, source, stream, source_record, conn, opts)
        end
      end)
    rescue
      error -> {:error, error}
    catch
      :throw, value -> {:error, value}
    end
  end

  defp lineage_wrap(nil, _run_id, fun), do: fun.()

  defp lineage_wrap(job, run_id, fun) do
    Lineage.run(job, run_id, fn ->
      case fun.() do
        {:ok, summary} = ok ->
          Lineage.emit_complete(job, run_id, counts: %{raw_dataset(job) => summary.landed})
          ok

        # A skipped-with-reason is a completed run that moved nothing.
        other ->
          other
      end
    end)
  end

  defp raw_dataset(job) do
    # job is a :sync descriptor — its name is bizev.sync.<source>.<stream>;
    # the dataset mirrors it.
    "bizev.raw." <> String.replace_prefix(job.name, "bizev.sync.", "")
  end

  defp resolve_conn(opts, source) do
    case Keyword.get(opts, :auth_provider) || AuthProvider.resolve(source) do
      {:ok, conn} -> {:ok, conn}
      {:error, :no_auth_provider} -> raise "no auth provider configured (config :ash_discrete_business_events, :auth_provider) — a source that cannot authenticate is a failed sync, never an anonymous one"
      {:error, reason} -> raise "auth edge failed: #{inspect(reason)}"
      provider when is_atom(provider) -> provider.resolve(source)
    end
  end

  defp sync_loop(adapter, source, stream, source_record, conn, opts) do
    cursor = Keyword.get(opts, :cursor)
    max_batches = Keyword.get(opts, :max_batches, @default_max_batches)
    region = Keyword.get(opts, :region, source.region)
    residency_tag = Keyword.get(opts, :residency_tag, to_string(region))
    fetched_at = Keyword.get(opts, :fetched_at) || DateTime.utc_now()

    state = %{
      adapter: adapter,
      source: source,
      stream: stream,
      source_record: source_record,
      conn: conn,
      region: region,
      residency_tag: residency_tag,
      fetched_at: fetched_at,
      limit: Keyword.get(opts, :limit),
      transport: Keyword.get(opts, :transport),
      cursor: cursor,
      landed: 0,
      batches: 0,
      api_calls_used: 0
    }

    run_batches(state, max_batches)
  end

  defp run_batches(state, remaining)

  defp run_batches(state, 0) do
    {:ok, summary(state)}
  end

  defp run_batches(state, remaining) do
    batch_opts =
      [limit: state.limit, api_calls_used: state.api_calls_used, transport: state.transport]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case state.adapter.fetch_batch(state.source, state.stream, state.conn, state.cursor, batch_opts) do
      {:ok, batch} ->
        state = %{state | api_calls_used: batch.api_calls_used || state.api_calls_used}
        landed = land_records(state, batch.records)

        state = %{
          state
          | landed: state.landed + landed,
            batches: state.batches + 1,
            cursor: batch.next_cursor || state.cursor
        }

        if batch.complete? do
          {:ok, summary(state)}
        else
          run_batches(state, remaining - 1)
        end

      {:error, %BudgetExhausted{} = exhausted} ->
        raise %BudgetExhausted{
          exhausted
          | landed: state.landed,
            cursor: last_completed_cursor(state)
        }

      {:error, reason} ->
        raise "sync batch failed: #{inspect(reason)}"
    end
  end

  # Records land through the LAND action — the typed boundary where
  # admission, idempotency and lineage attach (§1.2). A record that opens
  # a new period counts as landed; an identical re-observation is a
  # temporal no-op and does not.
  defp land_records(state, records) do
    adapter_field = cursor_field(state)
    cursor_key = to_string(state.source.cursor)

    Enum.count(records, fn record ->
      landed =
        state.source_record.land!(
          source: state.source.name,
          stream: state.stream.name,
          external_id: external_id(state, record),
          region: state.region,
          residency_tag: state.residency_tag,
          raw_payload: record,
          cursor: %{cursor_key => Map.get(record, adapter_field)},
          fetched_at: state.fetched_at
        )

      landed.valid_at.lower == state.fetched_at
    end)
  end

  defp external_id(_state, record), do: Map.fetch!(record, "Id")

  defp cursor_field(state), do: state.adapter.cursor_field(state.stream)

  # The cursor to park on failure: the LAST COMPLETED batch's cursor —
  # never the failed batch's partial view.
  defp last_completed_cursor(state), do: state.cursor

  defp summary(state) do
    %{
      landed: state.landed,
      batches: state.batches,
      cursor: state.cursor,
      api_calls_used: state.api_calls_used
    }
  end
end
