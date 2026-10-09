# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.VerifyMappingSources do
  @moduledoc """
  TODO(BIZEV-5): verify each `mapping`'s `source:` tuple names a declared
  `source` and one of its `stream`s, failing compilation otherwise.

  Registered on the extension now (BIZEV-2 freezes the extension's
  transformer list) and a pass-through until the mapping engine lands —
  a transformer that half-verifies is worse than one that verifies at
  all, because the false confidence outlives the scaffold.
  """

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state), do: {:ok, dsl_state}
end
