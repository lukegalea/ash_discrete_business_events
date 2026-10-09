# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

%{
  configs: [
    %{
      name: "default",
      strict: true,
      merge_with_default_config: true,
      # The ash_credo plugin: Ash-aware checks over the DSL state, plus the
      # run-scoped cache. Checks that introspect compiled modules need
      # `mix compile` first — the precommit alias orders credo after compile
      # for that reason.
      plugins: [{AshCredo, []}],
      checks: %{
        disabled: [
          # The house style favours fully-qualified calls into Ash's Info
          # modules and cross-module helpers — they are grep-friendly and
          # keep the called surface obvious at each site, so single-use
          # "alias this nested module" suggestions are noise.
          {Credo.Check.Design.AliasUsage, []},

          # TODO(BIZEV-N) tags are this package's slice markers: BIZEV-2
          # froze the contracts and left precisely-placed TODOs for the
          # resources (BIZEV-3/4), the mapping engine (BIZEV-5) and the
          # adapter callbacks (BIZEV-7). They are deliverables, not debt.
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
