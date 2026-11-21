# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo.Migrations.AddSimRunProjections do
  @moduledoc """
  The simulation projection's table (`sim_run_projections` — the
  `simulation_projection: true` fixture's target): a plain, non-temporal
  ProjectionResource whose grain is (region, subject, simulation_run),
  so two runs give two rows per subject.
  """

  use Ecto.Migration

  def up do
    create table(:sim_run_projections, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:region, :text, null: false)
      add(:subject, :text, null: false)
      add(:simulation_run, :text, null: false)
      add(:stage, :text)
      add(:amount, :bigint)
    end

    create(index(:sim_run_projections, [:region, :subject, :simulation_run], unique: true))
  end

  def down do
    drop(table(:sim_run_projections))
  end
end
