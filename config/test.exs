# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

import Config

# The projector engine's compile-time surface for THIS repo's own suite.
# The engine's internal resources (Checkpoint, DeadLetter, Registry) resolve
# their repo and table prefix via Application.compile_env, so this must be
# set before the dependency compiles. A HOST sets its own values — a lib
# package's config/ is never loaded by consumers; this file binds only this
# repo's builds. Projectors are not started here: the suite drives the
# package's region-scoped drain explicitly.
config :ash_events_projections,
  repo: AshDiscreteBusinessEvents.Test.Repo,
  table_prefix: "bizev_projection_",
  start_projectors?: false,
  start_probe?: false
