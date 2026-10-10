# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecordCursorTest do
  @moduledoc """
  Cursor-as-data and sync-reset-as-explicit-action (§2.3, §2.4 — the
  dogfood rulings, carried onto the temporal raw layer): cursors ride
  observations, advances are splits (never rewrites), reset is a visible
  historical event, and re-sync after reset can neither duplicate nor
  silently revise.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Fixtures.Observations
  alias AshDiscreteBusinessEvents.Fixtures.SourceRecord

  @moduletag :db

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(AshDiscreteBusinessEvents.Test.Repo)
    %{external_id: Observations.external_id()}
  end

  test "advance_cursor splits: the prior cursor keeps its period", %{external_id: external_id} do
    landed = Observations.land!(external_id: external_id)

    advanced =
      SourceRecord.advance_cursor!(landed, %{
        "system_modstamp" => "2026-10-03T09:00:00.000+0000"
      })

    # The current version carries the advanced cursor.
    assert advanced.cursor == %{"system_modstamp" => "2026-10-03T09:00:00.000+0000"}

    history = Observations.history(external_id)
    assert length(history) == 2

    [older, newer] = history
    assert older.cursor == %{"system_modstamp" => "2026-10-01T14:09:30.000+0000"}
    assert newer.cursor == %{"system_modstamp" => "2026-10-03T09:00:00.000+0000"}
    assert older.valid_at.upper == newer.valid_at.lower
  end

  test "reset_cursor is an explicit action — the drop is visible history, not an erasure", %{
    external_id: external_id
  } do
    landed =
      Observations.land!(
        external_id: external_id,
        cursor: %{"system_modstamp" => "2026-10-03T09:00:00.000+0000"}
      )

    reset = SourceRecord.reset_cursor!(landed)

    assert reset.cursor == nil

    history = Observations.history(external_id)
    assert length(history) == 2

    [older, newer] = history
    assert older.cursor == %{"system_modstamp" => "2026-10-03T09:00:00.000+0000"}
    assert newer.cursor == nil
  end

  test "re-sync after reset: same content with a fresh cursor is a new version, not a duplicate",
       %{
         external_id: external_id
       } do
    t1 = ~U[2026-10-01 14:09:41.000000Z]
    t2 = ~U[2026-10-02 08:15:12.000000Z]

    landed = Observations.land!(external_id: external_id, fetched_at: t1)
    SourceRecord.reset_cursor!(landed)

    # The full re-sync re-observes everything. Content is identical but
    # the cursor is fresh: the observation is written (it rides a new
    # cursor), opening a new period — exactly one, at the re-sync instant.
    resync =
      Observations.land!(
        external_id: external_id,
        fetched_at: t2,
        cursor: %{"system_modstamp" => "2026-10-02T08:00:00.000+0000"}
      )

    history = Observations.history(external_id)
    assert length(history) == 3

    # The re-sync never duplicates: a second pass at the same instant
    # (same content, same cursor) is a no-op.
    again =
      Observations.land!(
        external_id: external_id,
        fetched_at: t2,
        cursor: %{"system_modstamp" => "2026-10-02T08:00:00.000+0000"}
      )

    assert again.id == resync.id
    assert length(Observations.history(external_id)) == 3

    # …and it never silently revises: the pre-resync payload keeps its
    # period, unchanged.
    assert Enum.at(history, 0).raw_payload["StageName"] == "Qualification"
    assert Enum.at(history, 2).raw_payload["StageName"] == "Qualification"
  end
end
