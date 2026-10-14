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

  # The lint-level PII guard (§9 risk 5's minimization-at-mapping-time):
  # these canonical TARGET keys are refused outright — identifiers this
  # obviously personal belong in the raw layer only, documented with
  # `unmapped_because`. NOT a PII oracle: an exhaustive classifier is
  # impossible; this catches the obvious, cheaply, at compile time.
  @pii_targets ~w(email e_mail email_address mail phone phone_number mobile
                  ssn social_security_number tax_id national_id)

  @impl true
  def transform(dsl) do
    module = Spark.Dsl.Transformer.get_persisted(dsl, :module)

    problems =
      dsl
      |> Info.mappings()
      |> Enum.flat_map(fn mapping ->
        case Compiler.verify(Compiler.artifact(mapping)) do
          :ok -> pii_problems(mapping)
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

  defp pii_problems(mapping) do
    mapping.ops
    |> Enum.filter(fn op ->
      (op.target && Atom.to_string(op.target) in @pii_targets) and
        op.op != :unmapped_because
    end)
    |> Enum.map(fn op ->
      "[#{mapping.name}] canonical target `#{op.target}` looks like direct personal data " <>
        "(#{op.op}) — PII stays in the raw layer; map a structural fact instead or document " <>
        "the gap with `unmapped_because` (§9 risk 5, minimization at mapping time)"
    end)
  end
end
