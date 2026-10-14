# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.VerifyAdapters do
  @moduledoc """
  The adapter boundary's conformance verifier (§13.2's ruling, delivered):
  a source whose `adapter` doesn't export every
  `AshDiscreteBusinessEvents.Adapters.Adapter` callback fails the host's
  COMPILATION, not the first sync; a source declaring more than one
  `auth` strategy is rejected outright (the promotion of
  `Info.auth_of/1`'s old compile warning).

  A TRANSFORMER, not a Spark verifier — on Elixir 1.20, verifier errors
  surface from `after_verify` and only *warn*, and a conformance refusal
  that compiles is not a refusal (the same ruling VerifyMappings takes).
  """

  use Spark.Dsl.Transformer

  alias AshDiscreteBusinessEvents.Adapters.Adapter
  alias AshDiscreteBusinessEvents.Info

  @callbacks [cursor_field: 1, fetch_batch: 5, api_calls_per_batch: 0]

  @impl true
  def transform(dsl) do
    module = Spark.Dsl.Transformer.get_persisted(dsl, :module)

    problems =
      dsl
      |> Info.sources()
      |> Enum.flat_map(&source_problems/1)

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

  defp source_problems(source) do
    Enum.concat(auth_problems(source), adapter_problems(source))
    |> Enum.map(&"[source #{inspect(source.name)}] #{&1}")
  end

  # ADR 0011: ONE auth edge per source. More than one `auth` declaration
  # was tolerated with a warning in BIZEV-2/3; the boundary is real now,
  # and the ambiguity is a compile error.
  defp auth_problems(source) do
    case source.auth do
      [_single] -> []
      [] -> []
      auths -> ["declares #{length(auths)} auth strategies — a source has exactly ONE auth edge (ADR 0011); keep one `auth` declaration"]
    end
  end

  defp adapter_problems(source) do
    case source.adapter do
      nil -> []
      adapter -> conformance_problems(source, adapter)
    end
  end

  defp conformance_problems(_source, adapter) do
    case Code.ensure_compiled(adapter) do
      {:module, ^adapter} ->
        missing = Enum.reject(@callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end)

        case missing do
          [] ->
            []

          missing ->
            [
              "adapter #{inspect(adapter)} does not conform to #{inspect(Adapter)}: " <>
                "missing #{Enum.map_join(missing, ", ", fn {n, a} -> "#{n}/#{a}" end)}. " <>
                "A source whose adapter is not conformance-complete must not compile — " <>
                "the alternative is discovering this at the first sync."
            ]
        end

      _ ->
        ["adapter #{inspect(adapter)} is not available (not compiled or not a module)"]
    end
  end
end
