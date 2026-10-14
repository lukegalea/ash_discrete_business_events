# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Extension do
  @moduledoc """
  The Spark extension carrying the `business_events` section.

  Split from `AshDiscreteBusinessEvents.Dsl` (which holds the section and
  entity definitions) so the section struct exists as a compiled module
  before this one registers it — the ash_open_lineage shape.
  """

  use Spark.Dsl.Extension,
    sections: [AshDiscreteBusinessEvents.Dsl.business_events()],
    transformers: [
      # The mapping compiler's halves: sources verified, artifacts hashed,
      # refusals enforced. All TRANSFORMERS — a Spark verifier runs in
      # Elixir's after_verify hook, where a raised error only warns, and
      # a refusal that compiles is not a refusal.
      AshDiscreteBusinessEvents.Transformers.VerifyMappingSources,
      AshDiscreteBusinessEvents.Transformers.HashMappings,
      AshDiscreteBusinessEvents.Transformers.VerifyMappings,
      # The adapter boundary (§13.2, BIZEV-7): conformance complete or no
      # compile; one auth edge per source.
      AshDiscreteBusinessEvents.Transformers.VerifyAdapters
    ]
end
