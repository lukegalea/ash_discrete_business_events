# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Preparations.BySubject do
  @moduledoc """
  One region's events about one subject (and, when declared, one
  stream), in sequence order.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(
      region == ^query.arguments.region and
        subject_external_id == ^query.arguments.subject_external_id
    )
    |> then(fn query ->
      case query.arguments[:subject_stream] do
        nil -> query
        stream -> Ash.Query.filter(query, subject_stream == ^stream)
      end
    end)
    |> Ash.Query.sort(sequence: :asc)
  end
end
