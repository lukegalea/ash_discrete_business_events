# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

# Used by "mix format"
[
  # ash's (and spark's) formatter plugins keep the DSL blocks — the
  # `business_events` section, and the resource DSL BIZEV-3/4 hang off the
  # macros — shaped the same way ash projects format them.
  import_deps: [:ash, :ash_postgres, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
