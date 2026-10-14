# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Classifier do
  @moduledoc """
  The classification seam's test double (§5.3): a plain
  `Mappings.Classifier` implementation — no ash_decisions, no HTTP, a
  scripted decision.
  """

  use Agent

  alias AshDiscreteBusinessEvents.Mappings.Classifier

  @behaviour Classifier

  def start_link(_arg), do: Agent.start_link(fn -> :emit end, name: __MODULE__)

  def script(decision), do: Agent.update(__MODULE__, fn _ -> decision end)

  @impl Classifier
  def classify(_artifact, _payload, _canonical) do
    Agent.get(__MODULE__, & &1)
  end
end
