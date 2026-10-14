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
    repo = AshPostgres.DataLayer.Info.repo(ledger)
    table = AshPostgres.DataLayer.Info.table(ledger)

    %{rows: rows} =
      repo.query!(
        "SELECT record_id, extract(epoch from occurred_at)::bigint, data " <>
          "FROM #{table} WHERE region = $1",
        [to_string(source.region)]
      )

    last_data =
      Enum.reduce(rows, %{}, fn [record_id, epoch, data], acc ->
        acc
        |> Map.put_new(record_id, %{})
        |> put_in([record_id, Integer.to_string(epoch)], data)
      end)

    Enum.reduce_while(
      runs,
      {:ok, %{landed: 0, ledger_events: 0, cursor: nil, last_data: last_data}},
      fn run, {:ok, acc} ->
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

            acc = ledger_fold(artifact, source, stream, source_record, ledger, run, acc)
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
           cursor: acc.cursor,
           version_hash: validated.version_hash
         }}

      error ->
        error
    end
  end

  defp run_fetched_at(run) do
    case DateTime.from_iso8601(run["fetched_at"]) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # The mapping fold (§7's corrections rule): map the landed record; a
  # record whose canonical facts equal the subject's last ledgered event
  # is folded away — only genuine truth transitions become ledger rows.
  defp ledger_fold(artifact, source, stream, _source_record, ledger, run, acc) do
    records = read_run(run["file"])

    Enum.reduce(records, acc, fn record, acc ->
      external_id = record["Id"]

      with {:ok, canonical} <- Mappings.run(artifact, record, source_record_id: external_id),
           false <- already_ledgered?(acc, external_id, canonical) do
        record_transition(ledger, source, stream, external_id, canonical)
        bump(acc, external_id, canonical)
      else
        _ -> acc
      end
    end)
  end

  # The truth-point check: this subject's ledgered state AT this instant.
  # Known with the same data → already recorded (a replay folds away);
  # unseen or different → a new event (§7: corrections are events; the
  # original is never rewritten).
  defp already_ledgered?(acc, external_id, canonical) do
    point = Integer.to_string(DateTime.to_unix(canonical.occurred_at))
    known = acc.last_data[external_id] || %{}
    known[point] == canonical.data
  end

  defp record_transition(ledger, source, stream, external_id, canonical) do
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
      data: canonical.data
    })
  end

  defp bump(acc, external_id, canonical) do
    point = Integer.to_string(DateTime.to_unix(canonical.occurred_at))

    %{
      acc
      | ledger_events: acc.ledger_events + 1,
        last_data:
          Map.update(acc.last_data, external_id, %{point => canonical.data}, fn points ->
            Map.put(points, point, canonical.data)
          end)
    }
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
        nil -> {:ok, %{records: [], pk_chunked?: false}}
        run -> {:ok, %{records: FixtureCorpus.read_run(run["file"]), pk_chunked?: false}}
      end
    end
  end
end
