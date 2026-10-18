# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.HostBase do
  @moduledoc """
  A host's own resource base, as a host's platform base would be: one
  `use` that brings the data layer, the authorizer, a change every
  resource on it carries (`Fixtures.HostStamp`) and a policy every
  resource on it inherits (an actor must be present).

  `Fixtures.HostBasedLedger` stands on it, and passes it as its
  `:simulation_base`, so the twin stands on it too (BIZEV-10's
  host-base contract).
  """

  defmacro __using__(opts) do
    use_opts =
      Keyword.merge(
        [data_layer: AshPostgres.DataLayer, authorizers: [Ash.Policy.Authorizer]],
        opts
      )

    quote do
      use Ash.Resource, unquote(use_opts)

      changes do
        change AshDiscreteBusinessEvents.Fixtures.HostStamp, on: [:create]
      end

      policies do
        policy always() do
          authorize_if actor_present()
        end
      end
    end
  end
end
