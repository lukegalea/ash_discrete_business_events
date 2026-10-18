# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.HostBaseDomain do
  @moduledoc """
  The domain of the host-base ledger fixture. Not in `ash_domains`: the
  fixture rides the suite's existing ledger tables, so codegen must not
  try to migrate it a second time.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshDiscreteBusinessEvents.Fixtures.HostBasedLedger
    resource AshDiscreteBusinessEvents.Fixtures.HostBasedLedger.SimulationEvent
  end
end
