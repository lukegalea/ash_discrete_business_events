# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Source do
  @moduledoc """
  A declared external source — the `source` entity target.

  Declaration data only: the adapter boundary, auth placement, cursor
  strategy, region admission target, advisory rate budget, and the
  streams this source serves. Execution lives in the job templates
  (BIZEV-6/7).
  """

  defstruct name: nil,
            adapter: nil,
            auth: [],
            cursor: nil,
            region: nil,
            rate_budget: [],
            streams: [],
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom() | nil,
          adapter: module() | nil,
          auth: [AshDiscreteBusinessEvents.Dsl.Source.Auth.t()],
          cursor: atom() | nil,
          region: atom() | nil,
          rate_budget: keyword(),
          streams: [AshDiscreteBusinessEvents.Dsl.Source.Stream.t()]
        }
end
