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

# The projector engine's compile-time surface for THIS repo's own suite
# (BIZEV-8): the engine's internal resources (Checkpoint, DeadLetter,
# Registry) resolve their repo and table prefix via Application.compile_env,
# so this must be set before the dependency compiles. A HOST sets its own
# values — a lib package's config/ is never loaded by consumers; this file
# binds only this repo's builds. Projectors are not started here: the suite
# drives the package's region-scoped drain explicitly.
config :ash_events_projections,
  repo: AshDiscreteBusinessEvents.Test.Repo,
  table_prefix: "bizev_projection_",
  start_projectors?: false,
  start_probe?: false

# Ash's temporal gate (§4's mandate, mechanized) refuses the engine's ops
# applier on temporal projection resources because the package predates the
# gate. The change is temporal-safe by inspection — it translates ops into
# atomic field arithmetic and static sets; no wall clock, no side effects —
# so it is listed under the gate's own escape hatch. A HOST using temporal
# projections sets the same line; the upstream declaring the callback
# itself retires this.
config :ash, :temporal_safe_modules, [AshEvents.Projections.ApplyOpsChange]
