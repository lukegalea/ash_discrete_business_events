# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.Preparations.ByIdentity do
  @moduledoc """
  Narrows `:by_identity` to its identity-tuple arguments.

  The filter lives here rather than in a macro-emitted `filter expr`:
  inside a macro's quote, `^arg(:source)` is consumed as an unquote, so
  the constraint is applied at run time against the action's arguments.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    %{
      source: source,
      stream: stream,
      external_id: external_id,
      region: region
    } = query.arguments

    Ash.Query.filter(query,
      source: source,
      stream: stream,
      external_id: external_id,
      region: region
    )
  end

  # Temporal safety: pure query work — narrows by the caller's declared
  # identity, touches no clock and no data; `as_of` threads through.
  @impl true
  def temporal_safe?(_opts), do: true
end
