# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.TestSupport.LeakCheck do
  @moduledoc """
  The leak rule, executable (design §3.2's acceptance instrument): raises
  unless the term is clean of the forbidden strings.

  A lineage event must carry structural names only — job, dataset, region,
  mapping-version names. This walks the whole term (map keys included, any
  depth) using `AshDiscreteBusinessEvents.Lineage.leaks/2` and raises
  `ExUnit.AssertionError` listing every place a forbidden string appears.

  Deliberately sharp-edged, and the suite first proves the blade cuts: the
  leak test runs it against a deliberately-leaking map and asserts the raise
  before trusting it with real events — the ash_open_lineage pattern.
  """

  alias AshDiscreteBusinessEvents.Lineage
  alias ExUnit.AssertionError

  @spec assert_clean!(term(), [String.t()]) :: :ok
  def assert_clean!(term, forbidden) when is_list(forbidden) do
    case Lineage.leaks(term, forbidden) do
      [] ->
        :ok

      leaks ->
        raise AssertionError,
          message:
            "leaks forbidden values:\n" <>
              Enum.map_join(leaks, "\n", fn {path, value} ->
                "  #{path}: #{inspect(value)}"
              end) <>
              "\nforbidden: #{inspect(forbidden)}"
    end
  end
end
