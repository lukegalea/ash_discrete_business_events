# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Correlation do
  @moduledoc """
  The correlation seam's test double: an `AshOpenLineage.CorrelationProvider`
  implementation plus a `parent_id/0` parent-id provider, backed by an Agent
  so tests script the id, depth and enclosing-run id.

  Unstarted (or unscripted), it degrades to structural constants — a fixed
  test id and depth 0 — so a test that never touches the Agent still gets
  deterministic events. Opaque ids only: the leak rule is binding here too.
  """

  use Agent

  @behaviour AshOpenLineage.CorrelationProvider

  @fallback_id "bizev-test-correlation"
  @fallback_parent nil

  def start_link(_arg), do: Agent.start_link(fn -> %{id: @fallback_id, depth: 0, parent: @fallback_parent} end, name: __MODULE__)

  @doc "Scripts the correlation id and depth."
  def script(id, depth), do: Agent.update(__MODULE__, &%{&1 | id: id, depth: depth})

  @doc "Scripts the enclosing run's id (the parent facet's source)."
  def script_parent(parent), do: Agent.update(__MODULE__, &%{&1 | parent: parent})

  @impl AshOpenLineage.CorrelationProvider
  def id, do: state().id

  @impl AshOpenLineage.CorrelationProvider
  def depth, do: state().depth

  @doc "The `parent_id_provider` half: the enclosing run's id, or nil."
  def parent_id, do: state().parent

  defp state do
    case Process.whereis(__MODULE__) do
      nil -> %{id: @fallback_id, depth: 0, parent: @fallback_parent}
      _agent -> Agent.get(__MODULE__, & &1)
    end
  end
end
