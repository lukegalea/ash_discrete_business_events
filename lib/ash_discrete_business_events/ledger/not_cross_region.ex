# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.NotCrossRegion do
  @moduledoc """
  `cross_region_read` was invoked with fewer than two regions. A
  one-region question belongs to the region-scoped reads — the gate
  exists so the alarmed door is only opened when crossing is real.
  """

  use Splode.Error, fields: [:message], class: :invalid

  @impl true
  def message(%{message: message}), do: message
end
