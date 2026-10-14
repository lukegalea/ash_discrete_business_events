# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

# The lineage tests emit through the in-memory transport and the scripted
# correlation double; both are configured before any test runs (the fixture
# degrades to structural constants when its Agent isn't started, so tests
# that never script it stay deterministic too).
Application.put_env(:ash_open_lineage, :transport, AshOpenLineage.Transport.InMemory)

Application.put_env(
  :ash_open_lineage,
  :correlation_provider,
  AshDiscreteBusinessEvents.Fixtures.Correlation
)

Application.put_env(
  :ash_open_lineage,
  :parent_id_provider,
  AshDiscreteBusinessEvents.Fixtures.Correlation
)

# The fixture host and the macro-generated resources are the package
# under test; make sure everything is loaded before any test runs.
[
  AshDiscreteBusinessEvents.Fixtures,
  AshDiscreteBusinessEvents.Fixtures.StubAdapter,
  AshDiscreteBusinessEvents.Fixtures.Correlation,
  AshDiscreteBusinessEvents.Fixtures.Host,
  AshDiscreteBusinessEvents.Fixtures.Domain,
  AshDiscreteBusinessEvents.Fixtures.SourceRecord,
  AshDiscreteBusinessEvents.Fixtures.Ledger,
  AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent,
  AshDiscreteBusinessEvents.Fixtures.LedgerClearForReplay,
  AshDiscreteBusinessEvents.Fixtures.MappingVersion,
  AshDiscreteBusinessEvents.Fixtures.Projection,
  AshDiscreteBusinessEvents.Test.Repo
]
|> Enum.each(&Code.ensure_loaded!/1)

# The database is created and migrated here, once per test run, so a
# fresh clone needs no setup task; `SKIP_DB=1` excludes the `:db`-tagged
# tests for runs without a database. Migrations run outside the sandbox
# (:auto), and the pool is switched to manual ownership afterwards. (The
# ash_evidence / ash_judgments drill.)
#
# Order matters: storage_up runs BEFORE the repo starts. The sandbox pool
# opens its connections eagerly at start_link, so starting first on a
# fresh environment sprays a wall of `FATAL 3D000 database ... does not
# exist` errors before the create lands.
db_tests? =
  if Application.get_env(:ash_discrete_business_events, :db_tests_enabled?, true) do
    case AshDiscreteBusinessEvents.Test.Repo.__adapter__().storage_up(
           AshDiscreteBusinessEvents.Test.Repo.config()
         ) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    {:ok, _} = AshDiscreteBusinessEvents.Test.Repo.start_link()

    Ecto.Adapters.SQL.Sandbox.mode(AshDiscreteBusinessEvents.Test.Repo, :auto)

    Ecto.Migrator.run(AshDiscreteBusinessEvents.Test.Repo, "priv/test_repo/migrations", :up,
      all: true
    )

    Ecto.Adapters.SQL.Sandbox.mode(AshDiscreteBusinessEvents.Test.Repo, :manual)
    true
  else
    false
  end

ExUnit.start()

ExUnit.configure(exclude: if(db_tests?, do: [], else: [:db]))

unless db_tests? do
  IO.puts("note: SKIP_DB — excluding the database tests (:db tag)")
end
