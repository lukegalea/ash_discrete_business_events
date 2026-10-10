# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo do
  @moduledoc """
  The PostgreSQL repo behind the SUITE's fixture resources.

  The package's real resources are macro-generated on the host's base and
  ride the HOST's repo by construction — the macro emits no repo. This
  one exists so the suite can instantiate its fixtures on a real database
  without one: the credentials are test configuration
  (`config/config.exs`, `config/test.exs`), the migrations live in
  `priv/test_repo` (see `test/test_helper.exs`, which creates and
  migrates the database itself — a fresh clone needs no setup task).

  `btree_gist` is the temporal floor (the ash_judgments posture): the
  `WITHOUT OVERLAPS` identity on the fixture SourceRecord is a GiST
  exclusion constraint, and every non-GiST-native column in such a
  constraint needs this extension.
  """

  use AshPostgres.Repo,
    otp_app: :ash_discrete_business_events,
    warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["uuid-ossp", "ash-functions", "btree_gist"]

  # The family pins the declared floor to the server the programme
  # develops against (PostgreSQL 18; the ash_enterprise devenv provides
  # it). This is ash_postgres' feature-gating declaration, not a runtime
  # server check — and the temporal write machinery (PG18 `RETURNING
  # old`) needs it.
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
