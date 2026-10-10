# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecordReplayTest do
  @moduledoc """
  The replay-determinism proof (the E4 contract, adopted at the raw
  layer): re-landing the same observation sequence reproduces identical
  periods.

  The comparison projects each version onto its period bounds, content
  and observation instant (`Observations.period_shape/1`), deliberately
  excluding `id` and `recorded_at` — the id is generation-dependent and
  `recorded_at` is the wall clock of WHEN a version was written, which
  is its job to differ on replay. The PERIODS must not.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Observations

  @moduletag :db

  @external_id "0065f000003Xy7REPLAY"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    :ok
  end

  # The sequence a real sync produces, in emission order: two content
  # changes, a cursor-only ride (same payload, fresh cursor — a new
  # period by the no-op rule), and a final content change. All instants
  # are fixed, so the sequence never depends on the wall clock.
  defp replay_sequence do
    Observations.land!(%{
      external_id: @external_id,
      fetched_at: ~U[2026-10-01 14:09:41.000000Z],
      raw_payload: %{"StageName" => "Qualification"},
      cursor: %{"system_modstamp" => "2026-10-01T14:09:30.000+0000"}
    })

    Observations.land!(%{
      external_id: @external_id,
      fetched_at: ~U[2026-10-02 08:15:12.000000Z],
      raw_payload: %{"StageName" => "Proposal"},
      cursor: %{"system_modstamp" => "2026-10-02T08:00:00.000+0000"}
    })

    Observations.land!(%{
      external_id: @external_id,
      fetched_at: ~U[2026-10-02 12:00:00.000000Z],
      raw_payload: %{"StageName" => "Proposal"},
      cursor: %{"system_modstamp" => "2026-10-02T11:30:00.000+0000"}
    })

    Observations.land!(%{
      external_id: @external_id,
      fetched_at: ~U[2026-10-03 07:02:00.000000Z],
      raw_payload: %{"StageName" => "Negotiation"},
      cursor: %{"system_modstamp" => "2026-10-03T07:00:00.000+0000"}
    })
  end

  test "re-landing the same observation sequence reproduces identical periods" do
    replay_sequence()
    first_run = Enum.map(Observations.history(@external_id), &Observations.period_shape/1)

    assert length(first_run) == 4

    # Wipe every version of the identity and re-land the same sequence.
    import Ecto.Query

    AshDiscreteBusinessEvents.Test.Repo.delete_all(
      from(s in AshDiscreteBusinessEvents.Fixtures.SourceRecord,
        where: s.external_id == ^@external_id
      )
    )

    replay_sequence()
    replay_run = Enum.map(Observations.history(@external_id), &Observations.period_shape/1)

    assert replay_run == first_run
  end

  test "replay is also idempotent-in-place: re-landing into live history changes nothing" do
    replay_sequence()
    before = Enum.map(Observations.history(@external_id), &Observations.period_shape/1)

    # The same sequence again, WITHOUT wiping — every observation hits a
    # version carrying identical content and cursor: no-ops all the way
    # down.
    replay_sequence()

    assert Enum.map(Observations.history(@external_id), &Observations.period_shape/1) == before
  end

  test "the sequence fixture is what the proof above compares" do
    # Guard the proof itself: the fixture must exercise two content
    # changes and one cursor-only ride (if this drifts, the replay
    # assertions compare the wrong thing).
    replay_sequence()

    history = Observations.history(@external_id)
    assert length(history) == 4

    stages = Enum.map(history, & &1.raw_payload["StageName"])
    assert stages == ["Qualification", "Proposal", "Proposal", "Negotiation"]

    cursors = Enum.map(history, & &1.cursor["system_modstamp"])
    assert Enum.at(cursors, 1) == "2026-10-02T08:00:00.000+0000"
    assert Enum.at(cursors, 2) == "2026-10-02T11:30:00.000+0000"
  end
end
