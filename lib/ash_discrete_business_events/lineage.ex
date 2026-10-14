# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Lineage do
  @moduledoc """
  The lineage contract (design §3): the structural naming vocabulary, the
  run-identity split, and the job-template emission shape — the thin seam
  BIZEV-7's adapter (and any host job template) calls.

  ## Emission ownership and granularity (§3.1)

  The unit of data movement is the sync run (or webhook batch), not the row:
  N landed rows are ONE job. Emission is the job template's business —
  `START` before the run, `COMPLETE`/`FAIL` after, fail-loudly (silence is
  how a broken pipeline disappears from the graph while costing money).
  `run/3` is that template, ready-made. The AshOpenLineage notifier stays
  OFF the ledger and raw rows — they are high-volume machine writes where
  per-row COMPLETE events are noise; nothing in this package registers it.

  ## The structural naming vocabulary (§3.2)

  Fixed here so host-emitted STARTs and package-emitted COMPLETEs share the
  vocabulary by construction:

  | Thing | Name |
  |---|---|
  | sync job | `bizev.sync.<source>.<stream>` |
  | webhook job | `bizev.webhook.<source>` |
  | replay job | `bizev.replay.<projection>` |
  | raw dataset | `bizev.raw.<source>.<stream>` |
  | ledger dataset | `bizev.ledger.<region>` (per-region — a cross-region total is never one dataset) |
  | mapping-rule version | `bizev.rules.<mapping>.v<hash8>` (a mapping version is an INPUT dataset) |

  Stream ranges appear only as facet-level counts (`:counts` on
  `emit_complete/3`) — never boundary values. The leak rule is acceptance-
  tested with injected actor/tenant/customer/filter values, bites-proof
  included: `leaks/2` is the instrument.

  ## Run identity per job class (§3.3)

  Split by what the run must join to:

    * **Operational** runs (sync, webhook receipt, corrections, operator
      resets) are **correlation-derived**: `run_id(:operational)` is the host
      CorrelationProvider's id, so "which run landed this" is one lookup from
      the audit log.
    * **Derivation** runs (projection replays, re-mapping backfills) are
      **content-derived**: `run_id(%{purpose:, ledger_range:, mapping_versions:})`
      hashes the inputs, so the same replay maps to the SAME run instead of
      minting a look-alike — lineage demonstrates determinism. The operational
      history of replays (who, when) stays in the audit log via correlation;
      lineage carries the derivation edge, the audit log carries the
      operation. Two registers, two ids, each answering its own question.
  """

  alias AshDiscreteBusinessEvents.RunContext

  @namespace "bizev"
  @producer "https://github.com/lukegalea/ash_discrete_business_events"

  # The base-facet schema URL, same ruling as ash_open_lineage's: the 2-0-2
  # consolidated spec folds facets into #/$defs/BaseFacet.
  @base_facet_schema_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/BaseFacet"

  @count_facet "bizevStats"

  @type job_kind :: :sync | :webhook | :replay
  @type dataset :: String.t() | {String.t(), String.t()} | %{optional(:name) => String.t()}

  @emit_opts [:parent_run_id, :root, :correlation_id, :correlation_depth, :event_time, :producer]

  # ── the naming vocabulary ─────────────────────────────────────────────

  @doc "The OpenLineage namespace every BIZEV job and dataset lives in."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "The producer URI stamped on BIZEV's own facets (the count stats)."
  @spec producer() :: String.t()
  def producer, do: @producer

  @doc ~S"""
  The sync job for one stream: `bizev.sync.<source>.<stream>`.
  """
  @spec sync_job_name(atom() | String.t(), atom() | String.t()) :: String.t()
  def sync_job_name(source, stream), do: "bizev.sync.#{to_string(source)}.#{to_string(stream)}"

  @doc ~S"""
  The webhook receipt job for one source: `bizev.webhook.<source>`.
  """
  @spec webhook_job_name(atom() | String.t()) :: String.t()
  def webhook_job_name(source), do: "bizev.webhook.#{to_string(source)}"

  @doc ~S"""
  The replay job for one projection: `bizev.replay.<projection>`.
  """
  @spec replay_job_name(atom() | String.t()) :: String.t()
  def replay_job_name(projection), do: "bizev.replay.#{to_string(projection)}"

  @doc ~S"""
  The raw dataset a stream lands into: `bizev.raw.<source>.<stream>`
  (table-backed — the SourceRecord's `postgres` block is the storage this
  name points at).
  """
  @spec raw_dataset(atom() | String.t(), atom() | String.t()) :: String.t()
  def raw_dataset(source, stream), do: "bizev.raw.#{to_string(source)}.#{to_string(stream)}"

  @doc ~S"""
  The ledger dataset for ONE region: `bizev.ledger.<region>`. The per-region
  feed is its own dataset — a cross-region total is never one dataset (§6).
  """
  @spec ledger_dataset(atom() | String.t()) :: String.t()
  def ledger_dataset(region), do: "bizev.ledger.#{to_string(region)}"

  @doc ~S"""
  The mapping-rule version dataset: `bizev.rules.<mapping>.v<hash8>`. A
  mapping version is an INPUT dataset — the content hash in the name is the
  version; structural, not a value. Accepts the mapping name and its 8-char
  version hash, or a stored `MappingVersion` record.
  """
  @spec rules_dataset(atom() | String.t(), String.t()) :: String.t()
  def rules_dataset(mapping_name, version_hash) when is_binary(version_hash) do
    "bizev.rules.#{to_string(mapping_name)}.v#{version_hash}"
  end

  def rules_dataset(%{mapping_name: name, version_hash: hash}) do
    rules_dataset(name, hash)
  end

  # ── job builders ──────────────────────────────────────────────────────

  @doc """
  Builds the job descriptor for a BIZEV job kind — the map `run/3` and the
  `emit_*` wrappers take.

    * `job(:sync, source: :salesforce, stream: :opportunity)` — outputs the
      stream's raw dataset.
    * `job(:webhook, source: :stripe)` — receipt batch; add `stream:` to pin
      its raw output.
    * `job(:replay, projection: :pipeline_history)` — a derivation; add
      `region:` to read the region's ledger dataset and `mapping_versions:`
      (list of `{name, hash}` or `Lineage.rules_dataset/2` names) to pin the
      rule versions it runs under. Add `output:` for the derived dataset.

  The vocabulary is closed: only the options above are read, and extra keys
  are ignored on purpose — a job descriptor carries structural names, never
  whatever else the caller had in scope (the leak rule, structurally).
  """
  @spec job(job_kind(), keyword()) :: %{
          required(:namespace) => String.t(),
          required(:name) => String.t(),
          optional(:inputs) => [dataset()],
          optional(:outputs) => [dataset()]
        }
  def job(kind, opts \\ [])

  def job(:sync, opts) do
    source = Keyword.fetch!(opts, :source)
    stream = Keyword.fetch!(opts, :stream)

    descriptor(sync_job_name(source, stream), [], [raw_dataset(source, stream)])
  end

  def job(:webhook, opts) do
    source = Keyword.fetch!(opts, :source)

    outputs =
      case Keyword.fetch(opts, :stream) do
        {:ok, stream} -> [raw_dataset(source, stream)]
        :error -> []
      end

    descriptor(webhook_job_name(source), [], outputs)
  end

  def job(:replay, opts) do
    projection = Keyword.fetch!(opts, :projection)

    inputs =
      [] ++
        (case Keyword.fetch(opts, :region) do
           {:ok, region} -> [ledger_dataset(region)]
           :error -> []
         end) ++
        (case Keyword.fetch(opts, :mapping_versions) do
           {:ok, versions} -> Enum.map(versions, &rules_dataset_entry/1)
           :error -> []
         end)

    outputs =
      case Keyword.fetch(opts, :output) do
        {:ok, output} -> [output]
        :error -> []
      end

    descriptor(replay_job_name(projection), inputs, outputs)
  end

  defp descriptor(name, inputs, outputs) do
    %{namespace: @namespace, name: name, inputs: inputs, outputs: outputs}
  end

  defp rules_dataset_entry({name, hash}), do: rules_dataset(name, hash)
  defp rules_dataset_entry(name) when is_binary(name), do: name

  # ── run identity (§3.3) ───────────────────────────────────────────────

  @doc """
  The run id for a job class.

    * `run_id(:operational)` — **correlation-derived**: the host
      CorrelationProvider's id, so the lineage run joins the audit log's
      correlation record by one lookup.
    * `run_id(%{purpose:, ledger_range:, mapping_versions:})` —
      **content-derived** for derivation runs (replays, re-mapping
      backfills): a UUID (RFC 9562 v8 shape) hashed from the purpose atom,
      the input ledger range, and the mapping-version set. Same inputs ⇒ the
      same run id — an identical replay maps to the same run rather than
      minting a look-alike. The version set is order-insensitive (set
      semantics); the ledger range must be JSON-serializable.
  """
  @spec run_id(:operational) :: String.t()
  def run_id(:operational), do: AshOpenLineage.correlation_provider().id()

  @spec run_id(%{purpose: term(), ledger_range: term(), mapping_versions: [term()]}) ::
          String.t()
  def run_id(%{purpose: purpose} = spec) when is_map(spec) do
    canonical = %{
      "purpose" => to_string(purpose),
      "ledger_range" => Map.get(spec, :ledger_range),
      # Set semantics: the versions' order is not part of the content.
      "mapping_versions" =>
        spec |> Map.get(:mapping_versions, []) |> Enum.map(&to_string/1) |> Enum.sort()
    }

    canonical
    |> json!
    |> hash_uuid()
  end

  # ── the job-template emission shape (§3.1) ────────────────────────────

  @doc """
  The job template's emission shape, ready-made: emits START, runs the batch
  (however many rows that is — the BATCH is the unit), then emits COMPLETE —
  or FAIL, loudly, on a raise, throw or exit, re-raising the original.

  Emission failure never masks the job's own outcome: a lineage outage logs
  a warning and lets the batch's result stand. The FAIL path is always
  attempted — silence is how a broken pipeline disappears from the graph.

  Options: `:counts` (a map of output-dataset name → row count, attached as
  facet-level stats — stream ranges appear only as counts, never boundary
  values) plus the sanctioned emission options `:parent_run_id`, `:root`,
  `:correlation_id`, `:correlation_depth`, `:event_time`, `:producer`.
  """
  @spec run(%{required(:namespace) => String.t(), required(:name) => String.t()}, String.t(), (
          -> result
        )) :: result when result: var
  def run(job, run_id, fun) when is_map(job) and is_binary(run_id) and is_function(fun, 0) do
    emit_start(job, run_id)

    try do
      result = fun.()
      emit_complete(job, run_id)
      result
    rescue
      reason ->
        emit_fail(job, run_id, reason)
        reraise reason, __STACKTRACE__
    catch
      :throw, value ->
        emit_fail(job, run_id, {:job_failed, :throw, value})
        throw value

      :exit, value ->
        emit_fail(job, run_id, {:job_failed, :exit, value})
        exit(value)
    end
  end

  @doc "Emits the START RunEvent for `run_id` — call before the batch runs."
  @spec emit_start(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_start(job, run_id, opts \\ []) do
    AshOpenLineage.emit(job, emission(run_id, opts, event_type: :start))
  end

  @doc """
  Emits the COMPLETE RunEvent for `run_id` — call after the batch commits.
  `:counts` attaches facet-level row counts to the job's output datasets.
  """
  @spec emit_complete(map(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_complete(job, run_id, opts \\ []) do
    # The counts are facet-level stats on the OUTPUT datasets — they shape
    # the descriptor (whose inputs/outputs are the event's source of truth),
    # never the emission opts.
    job = with_count_facets(job, Keyword.get(opts, :counts))

    AshOpenLineage.emit(job, emission(run_id, opts, event_type: :complete))
  end

  @doc "Emits the FAIL RunEvent for `run_id` — the event that makes a broken batch visible."
  @spec emit_fail(map(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def emit_fail(job, run_id, reason, opts \\ []) do
    AshOpenLineage.fail(job, reason, emission(run_id, opts, []))
  end

  defp emission(run_id, opts, base) do
    base
    |> Keyword.put(:run_id, run_id)
    |> Keyword.merge(parent_opts())
    |> Keyword.merge(take_opts(opts))
  end

  # The closed emission vocabulary: only sanctioned keys ride through. An
  # arbitrary opts map (a filter value, a tenant, whatever the caller had in
  # scope) cannot reach the event — the leak rule, structurally.
  defp take_opts(opts), do: Keyword.take(opts, @emit_opts)

  defp with_count_facets(job, counts) when counts == %{} or is_nil(counts), do: job

  defp with_count_facets(job, counts) do
    Map.update(job, :outputs, [], &Enum.map(&1, fn d -> count_facet(d, counts) end))
  end

  # Outputs may be bare strings (placed in the job's namespace downstream) —
  # counts shape them into full descriptors.
  defp count_facet(name, counts) when is_binary(name) and is_map_key(counts, name) do
    %{name: name, facets: %{@count_facet => stats_facet(counts, name)}}
  end

  defp count_facet(%{name: name} = descriptor, counts) when is_map_key(counts, name) do
    Map.update(descriptor, :facets, %{@count_facet => stats_facet(counts, name)}, fn facets ->
      Map.put(facets, @count_facet, stats_facet(counts, name))
    end)
  end

  defp count_facet(other, _counts), do: other

  defp stats_facet(counts, name) do
    %{
      "_producer" => @producer,
      "_schemaURL" => @base_facet_schema_url,
      "rowCount" => Map.fetch!(counts, name)
    }
  end

  @doc ~S"""
  The parent-facet emission options: `[parent_run_id: id]` when the run is
  nested (depth > 0 per the correlation provider) and a parent id resolves —
  from the RunContext scope a worker re-established, or the sanctioned
  `parent_id_provider`. Depth 0 emits no parent facet, and a depth above
  zero without a resolvable id emits none either — the facet is omitted
  rather than fabricated.
  """
  @spec parent_opts() :: keyword()
  def parent_opts do
    if AshOpenLineage.correlation_provider().depth() > 0 do
      case RunContext.current_parent() || AshOpenLineage.parent_id() do
        nil -> []
        parent_run_id -> [parent_run_id: parent_run_id]
      end
    else
      []
    end
  end

  @doc """
  The leak rule, executable: walks a term (map keys included, any depth) and
  returns every place a forbidden string appears — `{path, value}` pairs.
  `[]` means clean. Facets carry structural names only; this is the
  instrument the acceptance test runs over every emitted event.
  """
  @spec leaks(term(), [String.t()]) :: [{String.t(), term()}]
  def leaks(term, forbidden) when is_list(forbidden), do: leaks(term, forbidden, [])

  # ── plumbing ──────────────────────────────────────────────────────────

  defp json!(term) do
    case Jason.encode(term) do
      {:ok, encoded} ->
        encoded

      {:error, reason} ->
        raise ArgumentError,
              "a derivation run id's ledger_range must be JSON-serializable — got: #{inspect(reason)}"
    end
  end

  # Content-derived ids take the RFC 9562 v8 shape (the deterministic
  # hash-based version): the digest's bits with the version nibble set to 8
  # and the variant bits to 10, so an OpenLineage consumer sees a UUID.
  defp hash_uuid(payload) do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = :crypto.hash(:sha256, payload)

    version = Bitwise.bor(0x8000, Bitwise.band(c, 0x0FFF))
    variant = Bitwise.bor(0x8000, Bitwise.band(d, 0x3FFF))

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, version, variant, e])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp leaks(binary, forbidden, path) when is_binary(binary) do
    if Enum.any?(forbidden, &String.contains?(binary, &1)) do
      [{render_path(path), binary}]
    else
      []
    end
  end

  defp leaks(atom, forbidden, path) when is_atom(atom) and not is_boolean(atom) do
    leaks(Atom.to_string(atom), forbidden, path)
  end

  defp leaks(map, forbidden, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      leaks(key, forbidden, path ++ ["<key>"]) ++ leaks(value, forbidden, path)
    end)
  end

  defp leaks(list, forbidden, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> leaks(item, forbidden, path ++ ["[#{index}]"]) end)
  end

  defp leaks(_other, _forbidden, _path), do: []

  defp render_path([]), do: "<root>"
  defp render_path(path), do: Enum.join(path, ".")
end
