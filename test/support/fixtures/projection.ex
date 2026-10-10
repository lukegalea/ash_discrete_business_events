# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.Projection do
  @moduledoc """
  A plain consumer resource for the replay test: the ledger's events
  drain through AshEvents' `:replay` action into this table (the §5.1
  claim — the projector engine and rebuilder come free with the
  substrate). Deliberately NOT events-audited itself: the ledger's rows
  are written directly, and replay must not re-record them.

  The actions are NAMED FOR THE BUSINESS KINDS (dotted atoms), because
  replay routes an event to `event.resource` by `event.action` — the
  ledger's kind IS the target action name.
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "fixture_projections"
    repo AshDiscreteBusinessEvents.Test.Repo
  end

  attributes do
    # writable id: replay applies the event's record_id (the subject's
    # external id) as the row's key, so the rebuild is byte-identical,
    # ids included.
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :stage, :string do
      allow_nil? false
      public? true
    end

    attribute :amount, :integer do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read]

    create :"opportunity.stage_changed" do
      accept [:id, :stage, :amount]
    end

    update :"opportunity.stage_amended" do
      accept [:stage, :amount]
    end
  end
end
