# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingVersion.Preparations do
  @moduledoc """
  The MappingVersion reads' preparations.
  """

  defmodule ByNameAndHash do
    @moduledoc "One version by its content identity: (mapping_name, version_hash)."
    use Ash.Resource.Preparation

    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      Ash.Query.filter(
        query,
        mapping_name == ^query.arguments.mapping_name and
          version_hash == ^query.arguments.version_hash
      )
    end
  end

  defmodule Active do
    @moduledoc "The active version of one mapping name."
    use Ash.Resource.Preparation

    require Ash.Query

    @impl true
    def prepare(query, _opts, _context) do
      Ash.Query.filter(
        query,
        mapping_name == ^query.arguments.mapping_name and status == :active
      )
    end
  end
end
