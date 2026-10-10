# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

# The package holds no thresholds, policy or adapter settings in config —
# adapter configuration is DSL data on the host's declaration, and
# credentials live at the auth edge (ADR 0011), never here. The only
# configuration is the test repository the suite runs against.
import Config

config :ash_discrete_business_events, ecto_repos: [AshDiscreteBusinessEvents.Test.Repo]

# The suite's fixture domain, so `mix ash.codegen` discovers the
# macro-generated fixture resource. Hosts list THEIR domain under their
# app's `ash_domains`; the fixture domain ships `validate_config_inclusion?:
# false` so a host that never sees it stays warning-free.
config :ash_discrete_business_events, ash_domains: [AshDiscreteBusinessEvents.Fixtures.Domain]

# With ash_postgres on the graph, Ash requires an explicit string length
# count (it is what SQL data layers count) — enforced at COMPILE time by
# the resource transformer, so this lives in the all-envs config.
# Codepoints is the recommended setting.
config :ash, default_string_length_count: :codepoints

# Defaults so `mix ash.codegen` / `mix ash.migrate` work against the
# devenv's Postgres with no extra setup; the test env (config/test.exs)
# overrides the database. `priv` is pinned so codegen, migrate and the
# test helper all agree on where the migrations live. Hosts point their
# OWN repo at their own database — the raw layer rides the host's repo
# by construction (the macro-generated resource declares it).
config :ash_discrete_business_events, AshDiscreteBusinessEvents.Test.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST") || System.get_env("PGHOST") || "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  priv: "priv/test_repo"

if config_env() == :test do
  import_config "test.exs"
end
