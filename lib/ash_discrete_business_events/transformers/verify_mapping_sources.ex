# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.VerifyMappingSources do
  @moduledoc """
  Verifies each `mapping`'s `source:` tuple names a DECLARED `source`
  and one of its `stream`s, failing compilation otherwise.

  A mapping wired to an undeclared stream would read payloads no job
  ever lands — the compile is where that lie dies. (Registered in
  BIZEV-2 as a frozen stub; this is its BIZEV-5 body.)
  """

  use Spark.Dsl.Transformer

  alias AshDiscreteBusinessEvents.Info

  @impl true
  def transform(dsl) do
    dsl
    |> Info.mappings()
    |> Enum.reduce_while({:ok, dsl}, fn mapping, {:ok, dsl} ->
      {source_name, stream_name} = mapping.source
      source = Info.source(dsl, source_name)

      cond do
        source == nil ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: Spark.Dsl.Transformer.get_persisted(dsl, :module),
              path: [:business_events, :mapping, mapping.name],
              message:
                "mapping reads from #{inspect(source_name)}, which is not a declared source"
            )}}

      Info.stream_of(source, stream_name) == nil ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: Spark.Dsl.Transformer.get_persisted(dsl, :module),
              path: [:business_events, :mapping, mapping.name],
              message:
                "mapping reads from stream #{inspect(stream_name)}, which is not declared " <>
                  "on source #{inspect(source_name)}"
            )}}

        true ->
          {:cont, {:ok, dsl}}
      end
    end)
  end
end
