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
      # Registered in BIZEV-2 to freeze the extension's transformer list;
      # both are pass-throughs until the mapping engine lands (BIZEV-5).
      AshDiscreteBusinessEvents.Transformers.VerifyMappingSources,
      AshDiscreteBusinessEvents.Transformers.HashMappings
    ]
end
