# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Preparations.RegionScoped do
  @moduledoc """
  Narrows a read to its declared `region` argument — the region
  discipline (§6): plain reads REQUIRE a region, enforced by the
  required argument and applied here. `:cross_region_scan` declares no
  region argument (it exists for the gated `cross_region_read` alone);
  this prep applies nothing for it.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case query.arguments[:region] do
      nil -> query
      region -> Ash.Query.filter(query, region == ^region)
    end
  end
end
