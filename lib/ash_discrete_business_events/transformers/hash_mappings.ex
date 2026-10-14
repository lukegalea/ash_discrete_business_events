# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.HashMappings do
  @moduledoc """
  Compiles each `mapping` entity into its content-hashed artifact and
  persists the hash on the entity (`mapping.hash`), so
  `AshDiscreteBusinessEvents.Info.mapping/2` hands back the exact
  pointer the ledger's provenance carries.

  The hash is over the mapping CONTENT (the canonical artifact: name,
  source, operators in declaration order — `Mappings.Compiler`), not
  its identity: renaming a rule is not changing it, and changing it must
  never look like a rename. Declaration order is part of the hash —
  ora-3 §13.3, pinned by test.
  """

  use Spark.Dsl.Transformer

  alias AshDiscreteBusinessEvents.Mappings.Compiler

  @impl true
  def transform(dsl) do
    dsl
    |> AshDiscreteBusinessEvents.Info.mappings()
    |> Enum.reduce(dsl, fn mapping, dsl ->
      {artifact, hash} = Compiler.compile(mapping)

      Spark.Dsl.Transformer.replace_entity(
        dsl,
        [:business_events],
        %{mapping | hash: hash, artifact: artifact},
        &(&1.name == mapping.name)
      )
    end)
  end
end
