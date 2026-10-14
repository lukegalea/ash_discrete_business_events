# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Domain do
  @moduledoc """
  The domain the fixture resources declare — what `mix ash.codegen`
  introspects and what the fixture resource's Ash calls route through.
  Ships `validate_config_inclusion?: false`: a library's fixture domain
  belongs in no host's `ash_domains`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDiscreteBusinessEvents.Fixtures.SourceRecord
    resource AshDiscreteBusinessEvents.Fixtures.Ledger
    resource AshDiscreteBusinessEvents.Fixtures.Ledger.SimulationEvent
    resource AshDiscreteBusinessEvents.Fixtures.MappingVersion
    resource AshDiscreteBusinessEvents.Fixtures.Projection
  end
end
