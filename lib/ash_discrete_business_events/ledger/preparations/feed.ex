# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Preparations.Feed do
  @moduledoc """
  The commit-order feed: one region, strictly after the consumer's
  high-water mark, in sequence order. Consumers resume by passing back
  the last seen `sequence`; because sequence order IS commit order per
  region (the lock's property), a cursor can never silently skip a row.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(region == ^query.arguments.region)
    |> Ash.Query.filter(sequence > ^(query.arguments.after_sequence || 0))
    |> Ash.Query.sort(sequence: :asc)
  end
end
