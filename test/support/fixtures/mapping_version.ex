# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.MappingVersion do
  @moduledoc """
  The macro-generated MappingVersion resource on the suite's own base —
  the same posture a host takes. Everything below the `use` line comes
  from the macro; this module contributes only the base.
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer

  use AshDiscreteBusinessEvents.Resources, :mapping_version

  postgres do
    table "mapping_versions"
    repo AshDiscreteBusinessEvents.Test.Repo
  end
end
