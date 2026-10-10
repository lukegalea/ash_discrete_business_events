# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.LedgerClearForReplay do
  @moduledoc """
  The log's `clear_records_for_replay` (AshEvents requires one before a
  replay run): clears the suite's replay consumer. In the real host this
  is BIZEV-8's wiring — the rebuild path's "from zero" step, clearing the
  LEDGER's consumers (never the ledger itself).
  """

  use AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_opts) do
    import Ecto.Query

    AshDiscreteBusinessEvents.Test.Repo.delete_all(
      from(p in AshDiscreteBusinessEvents.Fixtures.Projection)
    )

    :ok
  end
end
