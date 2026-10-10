# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.SourceRecord do
  @moduledoc """
  The macro-generated SourceRecord on the suite's own base — the same
  posture a host takes (`use AshDiscreteBusinessEvents.Resources,
  :source_record` inside a resource the HOST defines, on the HOST's
  domain and repo). Everything below the `use` line — the temporal
  section, the attributes, the identity, the actions — comes from the
  macro; this module contributes only the base (domain, data layer,
  table).
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  use AshDiscreteBusinessEvents.Resources, :source_record

  postgres do
    table "source_records"
    repo AshDiscreteBusinessEvents.Test.Repo
  end

  # The macro-not-concrete-module posture, proven: the HOST attaches its
  # own policy block and it governs the macro-generated actions natively
  # (ADR 0035's reversal clause — Spark builds policies at the package's
  # compile time, so concrete resource modules couldn't take this block).
  # The fixture's posture is permissive-by-default; a real host gates the
  # land and read actions per its own tenancy rules.
  policies do
    policy always() do
      authorize_if always()
    end
  end
end
