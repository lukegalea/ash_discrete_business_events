# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Mappings.Classifier do
  @moduledoc """
  The classification seam (§5.3): *which records become which event
  kind* — routing, thresholds — is not the mapping operators' job
  (they shape the event), and it is not THIS package's job (a
  DMN/ash_decisions evaluation is host wiring). It is a behaviour the
  mapping declaration may name (`classify_with`) and `run/3` honours.

  A pure decision over (artifact, payload, canonical-so-far):

    * `:emit` — record as built
    * `{:emit, kind}` — record, with the event kind overridden (the
      atom must be an existing kind — a compiled mapping name)
    * `{:skip, reason}` — do not record; the reason travels in the
      apply result (`{:ok, :skipped, reason}`)
    * `{:error, term}` — fail the apply loudly

  No hard dependency ships with this package: an ash_decisions-backed
  classifier is the host's adapter; tests use a plain module double.
  """

  @callback classify(
              artifact :: map(),
              payload :: map(),
              canonical :: map()
            ) ::
              :emit
              | {:emit, atom()}
              | {:skip, String.t()}
              | {:error, term()}
end
