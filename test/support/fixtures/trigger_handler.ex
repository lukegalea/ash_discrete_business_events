# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.TriggerHandler do
  @moduledoc """
  The BPMN-side test double: a scripted `Triggers.Handler` — captures
  every nudged ledger row (the event kind + correlation key the host's
  EventSource would dispatch on) and can be scripted to fail.
  """

  use Agent

  @behaviour AshDiscreteBusinessEvents.Triggers.Handler

  def start_link(_), do: Agent.start_link(fn -> %{script: :ok, nudged: []} end, name: __MODULE__)

  @doc "Scripts the nudge outcome: `:ok` or `{:error, reason}`."
  def script(outcome), do: Agent.update(__MODULE__, &%{&1 | script: outcome})

  @doc "Every ledger row nudged so far, oldest first."
  def nudged, do: Agent.get(__MODULE__, &Enum.reverse(&1.nudged))

  @impl AshDiscreteBusinessEvents.Triggers.Handler
  def nudge(event) do
    outcome =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.script, %{state | nudged: [event | state.nudged]}}
      end)

    outcome
  end
end
