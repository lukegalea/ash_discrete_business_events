# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Preparations.ById do
  @moduledoc """
  One event by id AND region — even a point lookup states its
  jurisdiction (§6).
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.filter(
      query,
      id == ^query.arguments.id and region == ^query.arguments.region
    )
  end
end
