# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecordAsOfTest do
  @moduledoc """
  The design's Oct-1 question (§1.3): *what did Salesforce say the stage
  was on Oct 1* is a query, not a replay — index-backed containment
  reads over the observation periods.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Observations
  alias AshDiscreteBusinessEvents.Fixtures.SourceRecord

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{external_id: Observations.external_id()}
  end

  test "what did the source say on Oct 1", %{external_id: external_id} do
    Observations.land!(external_id: external_id, fetched_at: ~U[2026-10-01 14:09:41.000000Z])

    Observations.land!(
      external_id: external_id,
      fetched_at: ~U[2026-10-02 08:15:12.000000Z],
      raw_payload: %{
        "Id" => external_id,
        "StageName" => "Negotiation",
        "SystemModstamp" => "2026-10-02T07:58:12.000+0000"
      }
    )

    # Oct 1, mid-afternoon: the source said Qualification.
    oct1 =
      SourceRecord.at!(
        :salesforce,
        :opportunity,
        external_id,
        :us,
        ~U[2026-10-01 16:00:00.000000Z]
      )

    assert oct1.raw_payload["StageName"] == "Qualification"
    assert oct1.__metadata__[:as_of] == ~U[2026-10-01 16:00:00.000000Z]

    # Oct 2, after the re-observation: Negotiation.
    oct2 =
      SourceRecord.at!(
        :salesforce,
        :opportunity,
        external_id,
        :us,
        ~U[2026-10-02 09:00:00.000000Z]
      )

    assert oct2.raw_payload["StageName"] == "Negotiation"

    # The period bounds are inclusive-exclusive: the instant the next
    # observation landed already reads as the new content.
    boundary =
      SourceRecord.at!(
        :salesforce,
        :opportunity,
        external_id,
        :us,
        ~U[2026-10-02 08:15:12.000000Z]
      )

    assert boundary.raw_payload["StageName"] == "Negotiation"
  end

  test "before the first observation, the source said nothing", %{external_id: external_id} do
    Observations.land!(external_id: external_id)

    assert SourceRecord.at!(
             :salesforce,
             :opportunity,
             external_id,
             :us,
             ~U[2026-10-01 14:00:00.000000Z]
           ) ==
             nil
  end

  test "the plain read is the as-of-now read", %{external_id: external_id} do
    Observations.land!(external_id: external_id, fetched_at: ~U[2026-10-01 14:09:41.000000Z])

    changed =
      Observations.land!(
        external_id: external_id,
        fetched_at: ~U[2026-10-02 08:15:12.000000Z],
        raw_payload: %{"Id" => external_id, "StageName" => "Negotiation"}
      )

    current = SourceRecord.by_identity!(:salesforce, :opportunity, external_id, :us)
    assert current.id == changed.id
    assert current.raw_payload["StageName"] == "Negotiation"
  end
end
