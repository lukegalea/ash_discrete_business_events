# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Source.Stream do
  @moduledoc """
  A declared stream within a source — the `stream` entity target.

  The stream is the second element of the SourceRecord identity tuple
  `(source, stream, external_id, region)` (design §1.3): two streams
  landing the same external id are two records, structurally.
  """

  defstruct name: nil,
            select: nil,
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom() | nil,
          select: String.t() | nil
        }
end
