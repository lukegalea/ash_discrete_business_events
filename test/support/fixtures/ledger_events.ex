# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.LedgerEvents do
  @moduledoc """
  Recording helpers shared by the ledger tests: the §1.4 example event
  (the BIZEV-2 contract fixture's opportunity stage change, against the
  real resource) with per-call unique subjects (the ash:testing deadlock
  rule — same-region writers serialize on the region lock, so identities
  must be globally unique across concurrent tests).
  """

  alias AshDiscreteBusinessEvents.Fixtures.Ledger

  def subject_external_id do
    "0065f" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 13, "0")
  end

  def provenance(overrides \\ %{}) do
    Map.merge(
      %{
        "mapping_name" => "opportunity_stage_changed",
        "mapping_version_hash" => "b3f2c9a1",
        "source_record_id" => Ash.UUID.generate()
      },
      overrides
    )
  end

  def event(overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        event_kind: :"opportunity.stage_changed",
        region: :us,
        residency_tag: "us",
        subject_type: "crm.opportunity",
        subject_external_id:
          Map.get_lazy(overrides, :subject_external_id, &subject_external_id/0),
        subject_stream: :opportunity,
        actor_type: "crm.user",
        actor_external_id: "0055f000001AbCdAAF",
        actor_display: "Dana Ops",
        occurred_at: ~U[2026-10-01 14:03:00.000000Z],
        observed_at: nil,
        context: %{
          "reason_code" => "stage_progression",
          "description" => "Stage moved from Qualification to Proposal"
        },
        provenance: provenance(),
        supersedes_event_id: nil,
        delivery_key: nil,
        data: %{
          "from_stage" => "Qualification",
          "to_stage" => "Proposal",
          "amount" => 95_000
        }
      },
      overrides
    )
  end

  def record!(overrides \\ []) do
    Ledger.record!(event(overrides))
  end

  def simulate!(overrides \\ []) do
    overrides =
      overrides
      |> Map.new()
      |> Map.put_new(:simulation_run, "demo-run-1")

    AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent.record!(event(overrides))
  end
end
