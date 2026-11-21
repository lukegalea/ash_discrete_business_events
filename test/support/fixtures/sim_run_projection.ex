# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.SimRunProjection do
  @moduledoc """
  The simulation projection's target: a plain (non-temporal)
  ProjectionResource whose grain includes `:simulation_run`, so two
  simulation runs give two rows per (region, subject) instead of
  overwriting each other — the row-per-run contract the
  `simulation_projection: true` option pins.
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  projection_resource do
    grain_fields([:region, :subject, :simulation_run])
  end

  attributes do
    uuid_primary_key :id

    attribute :region, :atom do
      allow_nil? false
      public? true

      description "The grain's region — projections never merge regions either (§6)."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 512

      description "The subject's external id — the ledger's record_id."
    end

    attribute :simulation_run, :string do
      allow_nil? false
      public? true

      description "The simulation run the row belongs to — part of the grain."
    end

    attribute :stage, :string do
      public? true

      description "The opportunity's stage as of the run."
    end

    attribute :amount, :integer do
      public? true

      description "The opportunity's amount as of the run."
    end
  end

  postgres do
    table "sim_run_projections"
    repo AshDiscreteBusinessEvents.Test.Repo
  end

  actions do
    read :read do
      primary? true
    end
  end
end
