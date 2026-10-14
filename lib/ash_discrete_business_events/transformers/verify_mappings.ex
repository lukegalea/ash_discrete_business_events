# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.VerifyMappings do
  @moduledoc """
  The mapping compiler's compile-time half: redundancy refused BY NAME
  (two operators writing the same target key fail, each named with its
  operator and declaration position), the known-dangerous combos refused
  (empty path/case lists, `occurred_at` declared unmapped), and the
  occurred-vs-observed discipline enforced — every mapping extracts
  `occurred_at` from the payload with a datetime type (§1.3).

  This is a TRANSFORMER, not a Spark verifier, on purpose: a verifier
  runs in Elixir's `after_verify` hook, where a raised error only
  *warns* — and a refusal that compiles is not a refusal. Transformers
  fail the defmodule outright.

  The structural rules live in `Mappings.Compiler.verify/1` so the
  `:validate` lifecycle action can re-run the SAME checks over a STORED
  artifact; this transformer bridges the DSL entities to it at compile
  time. Source-tuple verification is `VerifyMappingSources`' job.
  """

  use Spark.Dsl.Transformer

  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Mappings.Compiler

  @impl true
  def transform(dsl) do
    module = Spark.Dsl.Transformer.get_persisted(dsl, :module)

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
        {:ok, dsl}

      problems ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:business_events],
           message: Enum.join(problems, "; ")
         )}
    end
  end
end
