# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingVersion.InvalidArtifact do
  @moduledoc """
  A stored mapping artifact failed the compiler's structural checks —
  the `:validate` lifecycle action re-proves the ROW, so a drifted or
  hand-edited artifact is refused loudly instead of quietly disagreeing
  with the compiler.
  """

  use Splode.Error, fields: [:message], class: :invalid

  @impl true
  def message(%{message: message}), do: message
end
