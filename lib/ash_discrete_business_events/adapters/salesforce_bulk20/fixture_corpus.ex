# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus do
  @moduledoc """
  The fixture corpus's import path (§8's honest demo input): drives the
  committed CC0 corpus (`priv/fixtures/salesforce/`) through the FULL
  land → map → ledger pipeline — the same `Sync` runner, the same Bulk
  2.0 adapter logic, the same mapping applications and ledger records a
  live org would produce. Only the transport differs: each corpus run is
  served as one query job's download.

  ## Usage

      config :ash_discrete_business_events, :salesforce_bulk20_transport,
        AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.Transport

      config :ash_discrete_business_events, :auth_provider,
        AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.Auth

      {:ok, summary} =
        AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.import(
          host: MyApp.BusinessEvents,
          source: :salesforce,
          stream: :opportunity,
          source_record: MyApp.Platform.SourceRecord,
          ledger: MyApp.Platform.Ledger,
          mapping_name: :opportunity_stage_changed,
          mapping_version_resource: MyApp.Platform.MappingVersion
        )

  The import walks the manifest in order: for each run, `Sync.run/1`
  lands the snapshot (real SourceRecord periods — identical content is a
  temporal no-op), then every landed record is mapped through the
  ACTIVE mapping version and recorded to the ledger ONLY when its
  canonical facts differ from that subject's last ledgered event (§7's
  corrections rule). The mapping is published/validated/activated first,
  so every ledger row's provenance joins real `MappingVersion` data.

  Returns `{:ok, summary}` — runs, landed periods, ledger events, the
  final cursor, the active version hash. **Idempotent**: importing again
  lands nothing new (identical snapshots at the same `fetched_at` are
  no-ops) and records nothing new (identical canonical facts are
  skipped).

  The `Auth` module half is the test double for the auth edge (ADR 0011:
  Nango yields tokens): it resolves each run's conn — the transport
  reads the run index from it. `Auth.advance/0` moves to the next
  corpus run; `import/1` drives it.
  """

  alias AshDiscreteBusinessEvents.Adapters.Sync
  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Ledger.Corrections
  alias AshDiscreteBusinessEvents.Mappings
  alias AshDiscreteBusinessEvents.Mappings.Compiler

  # The corpus's auth-edge double — defined at the bottom of this file;
  # aliased up here for the import flow.
  alias AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.Auth

  @corpus_dir "priv/fixtures/salesforce"

  # ── the corpus itself ─────────────────────────────────────────────────

  @doc "The corpus directory (this package's priv, resolved per app env)."
  def dir do
    Application.get_env(:ash_discrete_business_events, :fixture_corpus_dir) ||
      Application.app_dir(:ash_discrete_business_events, @corpus_dir)
  end

  @doc "The parsed manifest: runs with their files and fetched_at instants."
  def manifest do
    dir()
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "Parses one corpus run's CSV into Bulk 2.0-shaped row maps."
  def read_run(file) do
    dir()
    |> Path.join(file)
    |> File.read!()
    |> parse_csv()
  end

  # ── the import ────────────────────────────────────────────────────────

  @spec import(keyword()) ::
          {:ok,
           %{
             runs: pos_integer(),
             landed: non_neg_integer(),
             ledger_events: non_neg_integer(),
             cursor: map() | nil,
             version_hash: String.t()
           }}
          | {:error, term()}
  def import(opts) do
    host = Keyword.fetch!(opts, :host)
    source_name = Keyword.fetch!(opts, :source)
    stream_name = Keyword.fetch!(opts, :stream)
    source_record = Keyword.fetch!(opts, :source_record)
    ledger = Keyword.fetch!(opts, :ledger)
    mapping_name = Keyword.fetch!(opts, :mapping_name)
    mapping_version_resource = Keyword.fetch!(opts, :mapping_version_resource)

    source = Info.source(host, source_name)
    stream = Info.stream_of(source, stream_name)

    # Publish → validate → activate: the ledger's provenance joins the
    # ACTIVE MappingVersion (§5.3). Publishing is content-addressed — a
    # re-import returns the already-active row instead of re-activating.
    {:ok, version} = Mappings.publish(host, mapping_name, mapping_version_resource)

    validated =
      if version.status == :active do
        version
      else
        {:ok, validated} = mapping_version_resource.validate_version(version)
        Mappings.activate!(validated)
      end

    mapping = Info.mapping(host, mapping_name)
    {artifact, _hash} = Compiler.compile(mapping)

    runs = manifest()["runs"]
    Auth.reset()

    # The corrections fold starts from HISTORY: every subject's ledgered
    # TRUTH-POINTS (occurred_at → data), so a re-import folds identical
    # canonical facts away against what the ledger already holds — a
    # replay of the same snapshots records nothing (§7). Raw SQL — only
    # (record_id, epoch, data) are needed, and the ledger row's machinery
    # columns (the replay-routing atom) are not this fold's business.
    # The corrections fold starts from HISTORY: the truth-point register
    # (§7 — see Ledger.Corrections) — so a replay folds identical facts
    # away, and a DIFFERENT fact at a known truth-point derives a
    # superseding event (corrections are events; originals are never
    # rewritten).
    register = Corrections.seed(ledger, source.region)

    runs
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok, %{landed: 0, ledger_events: 0, corrections: 0, cursor: nil, register: register}},
      fn {run, run_index}, {:ok, acc} ->
        Auth.advance()

        case Sync.run(
               source: source,
               stream: stream,
               source_record: source_record,
               cursor: acc.cursor,
               fetched_at: run_fetched_at(run),
               lineage_job: Keyword.get(opts, :lineage_job),
               transport: Keyword.get(opts, :transport, __MODULE__.Transport),
               auth_provider: Auth
             ) do
          {:ok, sync} ->
            acc = %{
              acc
              | landed: acc.landed + sync.landed,
                cursor: sync.cursor || acc.cursor
            }

            acc = ledger_fold(artifact, source, stream, ledger, run, run_index, acc)
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {run["file"], reason}}}
        end
      end
    )
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           runs: length(runs),
           landed: acc.landed,
           ledger_events: acc.ledger_events,
           corrections: acc.corrections,
           cursor: acc.cursor,
           version_hash: validated.version_hash
         }}

      error ->
        error
    end
  end

  @doc """
  Arms a revision from `run_file` onward: `rows` (Bulk 2.0 row maps,
  merged by `Id`) replace the served snapshot's rows for that run AND
  every later run — a restated truth propagates forward (§7). The
  corrections demo arms `corrections/revision-2026-06.csv`'s rows.
  """
  def arm_revision!(run_file, rows) do
    index =
      Enum.find_index(manifest()["runs"], &(&1["file"] == run_file))

    __MODULE__.Revisions.arm!(index + 1, rows)
    :ok
  end

  defp run_fetched_at(run) do
    case DateTime.from_iso8601(run["fetched_at"]) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # The mapping fold (§7's corrections rule): map the SAME rows the sync
  # served (revisions merged), classify each against the truth-point
  # register, and record new facts + superseding corrections — only
  # genuine truth transitions become ledger rows.
  defp ledger_fold(artifact, source, stream, ledger, run, run_index, acc) do
    records =
      run["file"]
      |> read_run()
      |> __MODULE__.Revisions.apply(run_index)

    Enum.reduce(records, acc, fn record, acc ->
      external_id = record["Id"]

      with {:ok, canonical} <-
             Mappings.run(artifact, record, source_record_id: external_id),
           outcome <-
             Corrections.classify(
               acc.register,
               external_id,
               canonical.occurred_at,
               canonical.data
             ),
           false <- outcome == :duplicate do
        fold_transition(acc, ledger, source, stream, external_id, canonical, outcome)
      else
        _ -> acc
      end
    end)
  end

  defp fold_transition(acc, ledger, source, stream, external_id, canonical, outcome) do
    supersedes = supersedes_event_id(outcome)

    recorded = record_transition(ledger, source, stream, external_id, canonical, supersedes)

    acc
    |> Map.update!(:ledger_events, &(&1 + 1))
    |> Map.update!(:corrections, fn c -> c + correction_count(outcome) end)
    |> Map.put(:register, register_after(acc.register, external_id, canonical, recorded))
  end

  defp register_after(register, external_id, canonical, recorded) do
    subject_points = Map.get(register.points, external_id, %{})
    point = Corrections.point_key(canonical.occurred_at)

    updated = Map.put(subject_points, point, %{data: canonical.data, event_id: recorded.id})
    %{register | points: Map.put(register.points, external_id, updated)}
  end

  defp supersedes_event_id({:correction, %{event_id: id}}), do: id
  defp supersedes_event_id(_), do: nil

  defp correction_count({:correction, _}), do: 1
  defp correction_count(_), do: 0

  defp record_transition(ledger, source, stream, external_id, canonical, supersedes) do
    ledger.record!(%{
      event_kind: canonical.event_kind,
      region: source.region,
      residency_tag: to_string(source.region),
      subject_type: "crm.opportunity",
      subject_external_id: external_id,
      subject_stream: stream.name,
      actor_type: "crm.system",
      occurred_at: canonical.occurred_at,
      provenance: canonical.provenance,
      supersedes_event_id: supersedes,
      process_ref: Map.get(canonical, :process_ref),
      data: canonical.data
    })
  end

  # Minimal CSV (same simplification as the Req transport): plain
  # comma-delimited rows, no embedded newlines.
  defp parse_csv(csv) do
    [header | data] =
      csv |> String.split(["\r\n", "\n"], trim: true) |> Enum.reject(&(&1 == ""))

    keys = String.split(header, ",")

    Enum.map(data, fn line ->
      Enum.zip(keys, String.split(line, ",")) |> Map.new()
    end)
  end

  defmodule Auth do
    @moduledoc """
    The corpus's auth-edge double: yields each run's conn (the transport
    reads the run index from it). `import/1` advances it per run.
    """
    use Agent

    def start_link(_), do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def reset, do: Agent.update(__MODULE__, fn _ -> 0 end)
    def advance, do: Agent.update(__MODULE__, &(&1 + 1))
    def run_index, do: Agent.get(__MODULE__, & &1)

    def resolve(_source), do: {:ok, %{corpus: true}}
  end

  defmodule Revisions do
    @moduledoc """
    Armed source revisions — the corrections demo's "the source rewrote
    history" (§7). A revision armed at run N merges its rows (keyed by
    `Id`) over THAT run's served snapshot AND EVERY LATER run: a
    restated truth propagates forward exactly as a rewritten source's
    snapshots would. `clear/0` disarms.
    """
    use Agent

    def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)

    @doc "Arms `rows` from run index `from_run_index` onward (merged by Id)."
    def arm!(from_run_index, rows) do
      Agent.update(__MODULE__, fn _ -> %{from: from_run_index, rows: List.wrap(rows)} end)
    end

    @doc "Merges the armed revision rows over `records` when `run_index` is at/after the arm point. Not started → no revisions (never a raise)."
    def apply(records, run_index) do
      case Process.whereis(__MODULE__) do
        nil ->
          records

        _agent ->
          do_apply(records, run_index)
      end
    end

    defp do_apply(records, run_index) do
      case Agent.get(__MODULE__, & &1) do
        %{from: from, rows: rows} when run_index >= from ->
          merge_by_id(records, rows)

        _ ->
          records
      end
    end

    defp merge_by_id(records, rows) do
      by_id = Map.new(rows, &{&1["Id"], &1})

      Enum.map(records, fn row ->
        case by_id[row["Id"]] do
          nil -> row
          revision -> Map.merge(row, revision)
        end
      end)
    end

    @doc "Disarms every revision."
    def clear, do: Agent.update(__MODULE__, fn _ -> nil end)
  end

  defmodule Transport do
    @moduledoc """
    The corpus's Bulk 2.0 transport double: each `create_query_job`/
    `download_results` exchange serves the CURRENT run's CSV verbatim —
    the CAPTURED download, exactly as the sync received it (the file is
    the recording, not a re-execution of the query). Rows the source
    delivered late (a SystemModstamp older than the cursor) are IN the
    recording, which is precisely the §7 shape the corpus exists to
    exercise.
    """
    @behaviour AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.Transport

    alias AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus

    @impl true
    def create_query_job(_conn, soql, _opts) do
      {:ok, %{soql: soql, run: FixtureCorpus.Auth.run_index()}}
    end

    @impl true
    def job_state(_conn, _job, _opts), do: {:ok, :completed}

    @impl true
    def download_results(_conn, %{run: run_index}, _opts) do
      runs = FixtureCorpus.manifest()["runs"]

      case Enum.at(runs, run_index - 1) do
        nil ->
          {:ok, %{records: [], pk_chunked?: false}}

        run ->
          rows =
            run["file"]
            |> FixtureCorpus.read_run()
            |> FixtureCorpus.Revisions.apply(run_index)

          {:ok, %{records: rows, pk_chunked?: false}}
      end
    end
  end
end
