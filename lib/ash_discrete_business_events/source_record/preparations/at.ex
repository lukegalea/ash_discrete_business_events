# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.Preparations.At do
  @moduledoc """
  The `:at` read — "what did the source say at T": narrows to the
  identity-tuple arguments and pins the read to the declared `as_of`
  instant. The pin becomes an index-backed containment predicate
  (`valid_at @> as_of`, served by the GiST exclusion index; the data
  layer's `set_as_of`).

  On a temporal resource a plain read already resolves to `now`; this
  preparation is what turns the declared instant into the read's time
  pin.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    %{
      source: source,
      stream: stream,
      external_id: external_id,
      region: region,
      as_of: as_of
    } = query.arguments

    query
    |> Ash.Query.filter(
      source: source,
      stream: stream,
      external_id: external_id,
      region: region
    )
    |> Ash.Query.as_of(as_of)
  end

  # Temporal safety: pure query work — narrows by the caller's declared
  # identity and pins the read to the caller's declared instant. No clock
  # reads, no side effects.
  @impl true
  def temporal_safe?(_opts), do: true
end
