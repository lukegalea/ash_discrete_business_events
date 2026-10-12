# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description """
  The canonical discrete business-event ledger for Ash: SourceRecord raw
  landing with temporal version history, a dedicated chained event ledger
  with commit-order sequences, and mappings-as-data — the land → map →
  ledger boundary external SaaS history enters the platform through.
  """

  def project do
    [
      app: :ash_discrete_business_events,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      source_url: "https://github.com/lukegalea/ash_discrete_business_events"
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # No supervision tree: the package owns no processes. The ledger's job
  # machinery (BIZEV-4) rides the host's Oban/Ash startup, and the resources
  # ride the host's Repo. If a process ever becomes genuinely necessary it
  # gets a named child_spec here with a comment saying why.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core: the Spark DSL substrate, the resources later slices ship and
      # their Postgres data layer. ash ~> 3.34 is the family floor (bumped
      # for EEF-CVE-2026-101028); ash_postgres >= 2.14.3 carries the
      # temporal support in tree (ADR 0049 mandate).
      {:ash, "~> 3.34"},
      {:ash_postgres, "~> 2.14"},
      {:spark, "~> 2.7"},

      # The ledger substrate (BIZEV-4 landed it): the ledger IS an
      # AshEvents event log, and the package compiles against it
      # (`RegionLockKeyGenerator` uses its lock-key behaviour, the ledger
      # transformer orders itself after its transformers). A real
      # dependency, so a host compiles ash_events before this package —
      # the ash_events fork (temporal as-of support, upstream #104).
      {:ash_events, github: "lukegalea/ash_events", branch: "temporal-as-of-support-0.7"},

      # The lineage contract (BIZEV-6): test-only until that slice lands —
      # lineage consumes ash_open_lineage's run-id/leak-rule vocabulary.
      {:ash_open_lineage, github: "lukegalea/ash_open_lineage", only: :test, runtime: false},

      # Dev hygiene: static analysis (credo with the ash_credo plugin).
      # Compile before credo — ash_credo's module checks need the BEAMs.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ash_credo, "~> 0.18", only: [:dev, :test], runtime: false},

      # The fixture SourceRecord proves the ADR 0035 posture (host policy
      # blocks govern macro-generated actions), and compiling policies
      # needs a SAT solver. Hosts with policies bring their own; the
      # suite uses the pure-Elixir one, test-only, no NIF.
      {:simple_sat, "~> 0.1", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_discrete_business_events",
        "Usage rules" =>
          "https://github.com/lukegalea/ash_discrete_business_events/blob/HEAD/usage-rules.md"
      },
      files: ~w(lib mix.exs README.md LICENSE LICENSES usage-rules.md docs .formatter.exs)
    ]
  end

  defp aliases do
    [
      # The house local gate, CI-less posture (same shape as ash_evidence /
      # ash_judgments). Order matters: compile first so ash_credo's
      # module-introspecting checks see BEAMs, credo before test so style
      # failures are cheap.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
