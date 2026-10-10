# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.Changes.AdmitResidency do
  @moduledoc """
  Zone/residency admission on the land path (design §1.3, ADR 0042's
  rule: admission is checked where data is first written, not at egress).

  Refuses until the observation is tagged, and refuses a tag that does
  not admit into the observation's target region. This is the exact TODO
  the dogfood left in its canonical projection ("do NOT add projectors
  for gmail/slack until admission checks residency at land time") — here
  it is the default, so no future source can ship without it.

  BIZEV-3 checks tag-presence and tag-vs-target agreement. The full
  zone machinery — per-zone ceilings and inadmissible-restriction lists
  against the host's zone declarations — wires here when the host's
  platform base is (BIZEV-11), on the same seam: this change module is
  where the check lives, so wiring it is extending the check, not
  moving it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &admit/1)
  end

  # Temporal safety: reads only the changeset's own inputs — no clock
  # reads, no side effects, no "now" assumptions. The admission decision
  # is about the observation being written, not about when it is written.
  @impl true
  def temporal_safe?(_opts), do: true

  defp admit(changeset) do
    region = Ash.Changeset.get_attribute(changeset, :region)
    tag = Ash.Changeset.get_attribute(changeset, :residency_tag)

    cond do
      is_nil(tag) ->
        # Unreachable through `:land` (the argument is required) but this
        # change guards the action itself — refuse until tagged.
        refuse(changeset, "refused: the observation is not residency-tagged")

      not regions_agree?(tag, region) ->
        refuse(
          changeset,
          "refused: residency tag #{inspect(tag)} does not admit into the target " <>
            "region #{inspect(region)} (ADR 0042: admission at land, per region)"
        )

      true ->
        changeset
    end
  end

  defp regions_agree?(_tag, nil), do: false

  defp regions_agree?(tag, region) when is_atom(region) do
    tag == Atom.to_string(region)
  end

  defp regions_agree?(_tag, _other), do: false

  defp refuse(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      AshDiscreteBusinessEvents.SourceRecord.AdmissionRefused.exception(message: message)
    )
  end
end
