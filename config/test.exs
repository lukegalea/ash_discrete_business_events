# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

import Config

# The suite talks to a real PostgreSQL through the sandboxed test repo
# (see test/support/test_repo.ex and test/test_helper.exs). `SKIP_DB=1`
# excludes the `:db`-tagged tests for runs without a database.
if System.get_env("SKIP_DB") do
  config :ash_discrete_business_events, :db_tests_enabled?, false
else
  config :ash_discrete_business_events, :db_tests_enabled?, true
end

# The suite's own database, created and migrated by the test helper on
# the fly — a fresh clone needs no setup task. The devenv's Postgres
# exports PGHOST/PGPORT and DB_USER/DB_PASSWORD (the family env pattern,
# so the devenv-wrapped invocation works unchanged).
config :ash_discrete_business_events, AshDiscreteBusinessEvents.Test.Repo,
  database: "ash_discrete_business_events_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000

# Ash loads relationships in spawned Tasks by default; those processes do
# not own the sandbox connection and hit DBConnection.OwnershipError
# intermittently. The standard fix, and what `mix igniter.install
# ash_postgres` writes.
config :ash, disable_async?: true

config :logger, level: :warning
