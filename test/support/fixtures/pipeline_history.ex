# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.PipelineHistory do
  @moduledoc """
  The temporal canonical projection (design §4's row: projections ARE
  temporal, host-side) — the projector engine's target for the equivalence
  gate. "Pipeline value of account X over time": one grain per
  (region, subject), one period per truth interval.

  Declares `temporal` (strategy :context) like the raw layer; the
  projector's writes run `as_of event.occurred_at`, so a late arrival or a
  correction reopens the period at the instant the truth changed — and the
  rebuild re-derives identical periods, which is exactly what BIZEV-8's
  gate pins.
  """

  use Ash.Resource,
    domain: AshDiscreteBusinessEvents.Fixtures.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Projections.ProjectionResource]

  temporal do
    strategy :context
    attribute :valid_at
    recorded_at :recorded_at
  end

  projection_resource do
    grain_fields([:region, :subject])
  end

  attributes do
    uuid_primary_key :id

    attribute :region, :atom do
      allow_nil? false
      public? true

      description "The grain's region — projections never merge regions either (§6)."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      constraints max_length: 512

      description "The subject's external id — the ledger's record_id, an idempotency key never an identity (VendorPM Law 1)."
    end

    attribute :stage, :string do
      public? true

      description "The opportunity's stage as of the period — the last projected truth."
    end

    attribute :amount, :integer do
      public? true

      description "The opportunity's amount as of the period."
    end

    attribute :corrections, :integer do
      allow_nil? false
      default 0
      public? true

      description "How many superseding events have restated this subject so far — corrections are events (§7), and the projection counts them."
    end

    # No create/update timestamps: the temporal machinery owns the wall
    # clock here — `recorded_at` is the write's stamp (the raw layer's
    # exact posture), and the period (`valid_at`) is validity.
  end

  postgres do
    table "pipeline_histories"
    repo AshDiscreteBusinessEvents.Test.Repo
  end

  actions do
    # The as-of surface: strategy :context makes plain reads the CURRENT
    # version of every grain; `Ash.Query.as_of/2` pins any instant —
    # "pipeline value of account X at T".
    read :read do
      primary? true
    end
  end
end
