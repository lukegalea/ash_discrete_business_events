# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Info do
  @moduledoc """
  Introspection for the `business_events` DSL section: the declared
  sources (with their streams and auth) and mappings, plus the host
  domains the declaration serves.

  All functions accept the host module (a `Spark.Dsl` module) or a
  persisted DSL map.
  """

  alias AshDiscreteBusinessEvents.Dsl

  @doc """
  The host Ash domains the declaration serves — the `domains:` option of
  `use AshDiscreteBusinessEvents, domains: [...]`. Empty when not declared.
  """
  @spec domains(module() | Spark.Dsl.t()) :: [atom()]
  def domains(dsl_state) do
    Spark.Dsl.Extension.get_persisted(dsl_state, :domains, [])
  end

  @doc """
  All declared sources, in declaration order.

  Entities persist under their section path, so sources and mappings
  share `[:business_events]` and are told apart by struct type.
  """
  @spec sources(module() | Spark.Dsl.t()) :: [Dsl.Source.t()]
  def sources(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:business_events])
    |> Enum.filter(&match?(%Dsl.Source{}, &1))
  end

  @doc """
  The declared source with the given name, or `nil`.
  """
  @spec source(module() | Spark.Dsl.t(), atom()) :: Dsl.Source.t() | nil
  def source(dsl_state, name) when is_atom(name) do
    dsl_state |> sources() |> Enum.find(&(&1.name == name))
  end

  @doc """
  The declared stream `name` within `source_name`, or `nil`.
  """
  @spec stream(module() | Spark.Dsl.t(), atom(), atom()) ::
          Dsl.Source.Stream.t() | nil
  def stream(dsl_state, source_name, stream_name)
      when is_atom(source_name) and is_atom(stream_name) do
    case source(dsl_state, source_name) do
      nil -> nil
      source -> stream_of(source, stream_name)
    end
  end

  @doc """
  The declared stream `name` within the given `t:Dsl.Source.t/0`, or `nil`.
  """
  @spec stream_of(Dsl.Source.t(), atom()) :: Dsl.Source.Stream.t() | nil
  def stream_of(%Dsl.Source{} = source, stream_name) when is_atom(stream_name) do
    Enum.find(source.streams, &(&1.name == stream_name))
  end

  @doc """
  The declared auth strategy for the given source name, or `nil` when the
  source declares none (or the source itself is undeclared).
  """
  @spec auth(module() | Spark.Dsl.t(), atom()) :: Dsl.Source.Auth.t() | nil
  def auth(dsl_state, source_name) when is_atom(source_name) do
    case source(dsl_state, source_name) do
      nil -> nil
      source -> auth_of(source)
    end
  end

  @doc """
  The auth strategy of the given `t:Dsl.Source.t/0` — a single `auth`
  declaration, or `nil`. More than one `auth` per source is a schema-level
  error waiting in BIZEV-7's verifier; today the first one wins and the
  extra is ignored, loudly enough in review.
  """
  @spec auth_of(Dsl.Source.t()) :: Dsl.Source.Auth.t() | nil
  def auth_of(%Dsl.Source{auth: []}), do: nil

  def auth_of(%Dsl.Source{auth: [auth | extra]}) do
    if extra != [] do
      IO.warn(
        "multiple `auth` declarations in one source; all but the first are ignored " <>
          "(a verifier rejecting this outright lands with BIZEV-7)"
      )
    end

    auth
  end

  @doc """
  All declared mappings, in declaration order.
  """
  @spec mappings(module() | Spark.Dsl.t()) :: [Dsl.Mapping.t()]
  def mappings(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_entities([:business_events])
    |> Enum.filter(&match?(%Dsl.Mapping{}, &1))
  end

  @doc """
  The declared mapping with the given name, or `nil`.
  """
  @spec mapping(module() | Spark.Dsl.t(), atom()) :: Dsl.Mapping.t() | nil
  def mapping(dsl_state, name) when is_atom(name) do
    dsl_state |> mappings() |> Enum.find(&(&1.name == name))
  end

  @doc """
  The `{source_name, stream_name}` tuple a mapping reads from — the
  mapping's declared `source:` option.
  """
  @spec mapping_source(Dsl.Mapping.t()) :: {atom(), atom()} | nil
  def mapping_source(%Dsl.Mapping{source: source}), do: source
end
