# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.BackdatedLanding do
  @moduledoc """
  A landing was attempted for an observation whose `fetched_at` precedes
  the identity's known history. Refused, not replayed or forced: taps
  deliver in cursor order, and reconstructing backdated history is the
  corrections slice's work (design §4, §7), not the land path's.
  """

  use Splode.Error, fields: [:message], class: :invalid

  @impl true
  def message(%{message: message}), do: message
end
