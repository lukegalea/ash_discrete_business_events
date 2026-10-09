# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Source.Auth do
  @moduledoc """
  A declared auth strategy for a source — the `auth` entity target.

  ADR 0011's boundary: the auth edge yields tokens; the connection id is
  never an action argument and no credential is DSL data. This struct
  records *where* auth lives, never *what* the credentials are.
  """

  defstruct strategy: nil,
            provider: nil,
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          strategy: atom() | nil,
          provider: String.t() | nil
        }
end
