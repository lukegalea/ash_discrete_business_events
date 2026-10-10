# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.AdmissionRefused do
  @moduledoc """
  Zone/residency admission refused on the land path: the observation is
  untagged, or its tag does not admit into the target region (ADR 0042).
  The raw layer's default — no source ships without an admission check.
  """

  use Splode.Error, fields: [:message], class: :forbidden

  @impl true
  def message(%{message: message}), do: message
end
