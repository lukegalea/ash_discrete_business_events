# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.CorpusProjector do
  @moduledoc """
  The corpus end-to-end's projector: folds the corpus's Opportunity
  ledger events into the temporal PipelineHistory projection (BIZEV-8's
  resource, reused — the demo-path's "pipeline value of account X over
  time"), so the fixture import can be read AS OF any corpus instant.

  Corrections arrive as DATA (§7): a superseding event's
  `supersedes_event_id` drives the ops — the truth is RESTATED (the
  temporal projection reopens the period at the correction's own truth
  instant — BIZEV-8's machinery) and the correction is counted, never
  hidden.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "corpus_pipeline_history_v1",
    event_log: AshDiscreteBusinessEvents.Fixtures.Ledger,
    projection_resource: AshDiscreteBusinessEvents.Fixtures.PipelineHistory

  grain(fn event -> %{region: event.region, subject: event.record_id} end)

  project("opportunity_stage_changed", fn event ->
    [
      {:set, :stage, event.data["stage"]},
      {:set, :amount, event.data["amount"]},
      {:increment, :corrections, correction_count(event)}
    ]
  end)

  defp correction_count(%{supersedes_event_id: id}) when not is_nil(id), do: 1
  defp correction_count(_), do: 0
end
