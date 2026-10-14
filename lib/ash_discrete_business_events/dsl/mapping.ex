# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Mapping do
  @moduledoc """
  A declared raw → canonical mapping — the `mapping` entity target.

  One event kind's rule. The transformer compiles each declared mapping
  to its content-hashed artifact (`hash`, `artifact` — the operators in
  declaration order are the hash's input, ora-3 §13.3); the hash rides
  every ledger row the rule produces as provenance, so the mapping that
  produced any event is reconstructable from the row alone. Publish it
  with `AshDiscreteBusinessEvents.Mappings.publish/4` into a
  `MappingVersion` resource (draft → validate → activate).
  """

  defstruct name: nil,
            source: nil,
            ops: [],
            hash: nil,
            artifact: nil,
            classify_with: nil,
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom() | nil,
          source: {atom(), atom()} | nil,
          ops: [AshDiscreteBusinessEvents.Dsl.Mapping.Op.t()],
          hash: String.t() | nil,
          artifact: map() | nil,
          classify_with: module() | nil
        }
end
