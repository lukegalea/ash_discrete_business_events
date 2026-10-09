# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Mapping do
  @moduledoc """
  A declared raw → canonical mapping — the `mapping` entity target.

  One event kind's rule. Compiles (from BIZEV-5) to a content-hashed,
  versioned artifact; the hash rides every ledger row the rule produces
  as provenance. The `ops` field is the closed operator vocabulary's
  landing place — deliberately empty in BIZEV-2 (the shape-freeze
  slice); the operator entities arrive with BIZEV-5 and are refused
  before then, on sight, by the schema.
  """

  defstruct name: nil,
            source: nil,
            ops: [],
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom() | nil,
          source: {atom(), atom()} | nil,
          ops: [struct()]
        }
end
