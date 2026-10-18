# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.HostStamp do
  @moduledoc """
  The host base's change: marks every row it creates
  (`context["host_base"] == true`), so a test can tell a row was written
  through the host's base rather than a bare resource.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    context = Ash.Changeset.get_attribute(changeset, :context) || %{}
    Ash.Changeset.force_change_attribute(changeset, :context, Map.put(context, "host_base", true))
  end
end
