# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.AuthProvider do
  @moduledoc """
  The auth edge (ADR 0011): Nango — or whatever the host uses — yields
  tokens. The host configures ONE provider; the sync runner resolves the
  connection through it before the adapter runs. A connection id is
  never an action argument, and no credential ever becomes BIZEV data.

      config :ash_discrete_business_events, :auth_provider,
        MyApp.Platform.NangoAuth

  The callback returns the adapter's `conn` — whatever the adapter's
  transport needs (for Bulk 2.0: `%{instance_url: url, token: token}`).
  Opaque to BIZEV: the package never opens it.
  """

  @callback resolve(AshDiscreteBusinessEvents.Dsl.Source.t()) ::
              {:ok, conn :: term()} | {:error, term()}

  @doc """
  The configured provider, or `nil`. The sync runner fails a run loudly
  when resolving against `nil` — a source that cannot authenticate is a
  failed sync, never an anonymous one.
  """
  @spec configured() :: module() | nil
  def configured do
    Application.get_env(:ash_discrete_business_events, :auth_provider)
  end

  @doc """
  Resolves the conn for `source` through the configured provider.
  `{:error, :no_auth_provider}` when none is configured — the caller
  (the sync runner) turns that into a visible FAIL.
  """
  @spec resolve(AshDiscreteBusinessEvents.Dsl.Source.t()) ::
          {:ok, conn :: term()} | {:error, :no_auth_provider | term()}
  def resolve(source) do
    case configured() do
      nil -> {:error, :no_auth_provider}
      provider -> provider.resolve(source)
    end
  end
end
