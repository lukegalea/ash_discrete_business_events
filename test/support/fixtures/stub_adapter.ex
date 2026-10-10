# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Fixtures.StubAdapter do
  @moduledoc """
  A stand-in adapter module for the fixture source.

  A plain module, deliberately: the boundary behaviour has no callbacks
  until BIZEV-7 shapes them, and a zero-callback module cannot be
  `@behaviour`-adopted without a compiler warning. When the callbacks
  land, this becomes `@behaviour`-compliant and the schema's
  `{:behaviour, ...}` documentation becomes enforced verification.
  """
end
