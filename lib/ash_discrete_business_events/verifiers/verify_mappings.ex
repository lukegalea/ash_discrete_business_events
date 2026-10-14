# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Verifiers.VerifyMappings do
  @moduledoc """
  The mapping compiler's compile-time half: redundancy refused BY NAME
  (two operators writing the same target key fail, each named with its
  operator and declaration position), the known-dangerous combos refused
  (empty path/case lists, `occurred_at` declared unmapped), and the
  occurred-vs-observed discipline enforced — every mapping extracts
  `occurred_at` from the payload with a datetime type (§1.3).

  The structural rules live in `Mappings.Compiler.verify/1` so the
  `:validate` lifecycle action can re-run the SAME checks over a STORED
  artifact; this verifier bridges the DSL entities to it at compile
  time. Source-tuple verification is `VerifyMappingSources`' job.
  """

  use Spark.Dsl.Verifier

  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Mappings.Compiler

  @impl true
  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    problems =
      dsl
      |> Info.mappings()
      |> Enum.flat_map(fn mapping ->
        case Compiler.verify(Compiler.artifact(mapping)) do
          :ok -> []
          {:error, problems} -> Enum.map(problems, &"[#{mapping.name}] #{&1}")
        end
      end)

    case problems do
      [] ->
        :ok

      problems ->
        {:error,
         Enum.map(problems, fn message ->
           Spark.Error.DslError.exception(
             module: module,
             path: [:business_events],
             message: message
           )
         end)}
    end
  end
end
