# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Transformers.HashMappings do
  @moduledoc """
  TODO(BIZEV-5): compile each `mapping` entity into a content-hashed,
  versioned artifact (draft → validate → activate — the ash_decisions
  snapshot pattern) and persist the hash so ledger-row provenance
  (`mapping_version_hash`) points into replayable data.

  Registered on the extension now (BIZEV-2 freezes the extension's
  transformer list) and a pass-through until the mapping engine lands.
  The hash is over the mapping *content*, not its name: renaming a rule
  is not changing it, and changing it must never look like a rename.
  """

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state), do: {:ok, dsl_state}
end
