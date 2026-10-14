# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.BudgetExhausted do
  @moduledoc """
  The source's `rate_budget` is spent — the job FAILs visibly (§7: the
  feed pauses, it does not degrade). Carries what the completed portion
  of the run achieved so the caller can park the cursor there: the next
  sync resumes strictly after it.
  """

  use Splode.Error, fields: [:message, :landed, :cursor, :calls_used], class: :invalid

  @impl true
  def message(%{message: message}), do: message
end
