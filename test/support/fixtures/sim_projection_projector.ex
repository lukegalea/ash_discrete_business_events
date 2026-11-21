# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.SimProjectionProjector do
  @moduledoc """
  The `simulation_projection: true` projector: it drains the
  SimulationEvent twin only, and its grain includes the run the twin
  rows carry — two runs give two rows in
  `AshDiscreteBusinessEvents.Fixtures.SimRunProjection`, one per run.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "sim_projection_v1",
    event_log: AshDiscreteBusinessEvents.Fixtures.Ledger,
    projection_resource: AshDiscreteBusinessEvents.Fixtures.SimRunProjection,
    simulation_projection: true

  grain(fn event ->
    %{region: event.region, subject: event.record_id, simulation_run: event.simulation_run}
  end)

  project("opportunity_stage_changed", fn event ->
    [
      {:set, :stage, event.data["stage"]},
      {:set, :amount, event.data["amount"]}
    ]
  end)
end
