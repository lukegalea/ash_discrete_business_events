# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Mapping.Op do
  @moduledoc """
  One operator of a mapping body — the unified target for the closed
  vocabulary (`map`, `decode`, `coalesce`, `concat`, `constant`,
  `unmapped_because`).

  Each operator has its OWN entity schema (schema-verified options: a
  typo is a compile error, and each shape accepts only its own options),
  while storage is one struct discriminated by `op`. Declaration order is
  the order of `AshDiscreteBusinessEvents.Dsl.Mapping.ops` — and that
  order is what the content hash covers (ora-3 §13.3: never Map
  iteration).
  """

  @ops [:map, :decode, :coalesce, :concat, :constant, :unmapped_because]

  defstruct op: nil,
            target: nil,
            from: nil,
            type: nil,
            cases: nil,
            default: nil,
            separator: nil,
            value: nil,
            reason: nil,
            __spark_metadata__: nil

  @type op_name :: :map | :decode | :coalesce | :concat | :constant | :unmapped_because

  @type t :: %__MODULE__{
          op: op_name() | nil,
          target: atom() | nil,
          from: String.t() | [String.t()] | nil,
          type: atom() | nil,
          cases: map() | nil,
          default: term(),
          separator: String.t() | nil,
          value: term(),
          reason: String.t() | nil,
          __spark_metadata__: term()
        }

  @doc "The closed vocabulary — nothing outside this list parses."
  @spec ops() :: [op_name()]
  def ops, do: @ops
end
