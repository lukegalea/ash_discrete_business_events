# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.PipelineProjector do
  @moduledoc """
  The demo projector (§5.1's shape, unchanged): kind-only routing over the
  ledger — `project "opportunity.stage_changed", fn event -> ops end` —
  folding business events into the temporal PipelineHistory projection.

  The handler sees the full §1.4 ledger row: `action` (the kind),
  `record_id` (the subject's external id), `data`, `region`,
  `occurred_at` (truth time), `supersedes_event_id` (corrections are
  events), `sequence` (commit order).

  The ops are order-deterministic per subject (§7's projector ruling —
  the property the replay-equivalence gate stands on): the stage and
  amount are set verbatim from the event, the correction counter
  increments only on supersession.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "pipeline_history_v1",
    event_log: AshDiscreteBusinessEvents.Fixtures.Ledger,
    projection_resource: AshDiscreteBusinessEvents.Fixtures.PipelineHistory

  grain(fn event -> %{region: event.region, subject: event.record_id} end)

  project("opportunity.stage_changed", fn event ->
    # The handler validates its input shape: a kind it routes but cannot
    # digest FAILS LOUDLY (and the drain quarantines it in the DeadLetter)
    # instead of folding garbage into the projection.
    stage = event.data["to_stage"]

    unless is_binary(stage) do
      raise ArgumentError,
            "undigestible #{inspect(event.action)}: data[\"to_stage\"] is not a string " <>
              "(subject #{inspect(event.record_id)})"
    end

    [
      {:set, :stage, stage},
      {:set, :amount, event.data["amount"]},
      {:increment, :corrections, supersession_count(event)}
    ]
  end)

  defp supersession_count(%{supersedes_event_id: nil}), do: 0
  defp supersession_count(%{supersedes_event_id: id}) when not is_nil(id), do: 1
end
