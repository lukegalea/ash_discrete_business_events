# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.StubAdapter do
  @moduledoc """
  A conformance-complete stand-in adapter for the fixture source: the
  DSL's `{:behaviour, Adapter}` contract is now ENFORCED (BIZEV-7's
  verifier rejects a non-conforming adapter at host compile time), so
  the fixture source's adapter must export the real callbacks. It never
  fetches anything — its batches come from nowhere and fail loudly if a
  test ever drives a sync with it.
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  @impl true
  def cursor_field(_stream), do: "SystemModstamp"

  @impl true
  def fetch_batch(_source, _stream, _conn, _cursor, _opts) do
    {:error, "the stub adapter fetches nothing — use the corpus transport in sync tests"}
  end

  @impl true
  def api_calls_per_batch, do: 1
end
