# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.CrossRegionRead do
  @moduledoc """
  The `:cross_region_read` run: validate that this really is a
  cross-region read (two or more regions — a one-region query belongs to
  the region-scoped reads), record one DISCLOSURE row per queried region
  (each in its own region's chain — the disclosure is itself chained
  history), then scan the queried regions. ADR 0042's flow rule: a
  cross-region total is shown WITH its jurisdictions, never without.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshDiscreteBusinessEvents.Ledger.NotCrossRegion

  @disclosure_kind :"region.disclosure"
  @disclosure_provenance %{
    "mapping_name" => "cross_region_disclosure",
    "mapping_version_hash" => "operator",
    "source_record_id" => nil
  }

  @impl true
  def run(input, _opts, _context) do
    resource = input.resource
    regions = Enum.uniq(input.arguments.regions)
    purpose = input.arguments.purpose

    if length(regions) < 2 do
      {:error,
       NotCrossRegion.exception(
         message:
           "cross_region_read requires at least two regions, got #{inspect(regions)}; " <>
             "one-region questions belong to the region-scoped reads"
       )}
    else
      now = DateTime.utc_now()

      Enum.each(regions, fn region ->
        resource
        |> Ash.Changeset.for_create(:append, %{
          region: region,
          residency_tag: Atom.to_string(region),
          subject_type: "platform.region",
          subject_external_id: Atom.to_string(region),
          occurred_at: now,
          provenance: @disclosure_provenance,
          data: %{
            "regions" => Enum.map(regions, &Atom.to_string/1),
            "purpose" => purpose
          },
          event_kind: @disclosure_kind
        })
        |> Ash.create!()
      end)

      rows =
        resource
        |> Ash.Query.for_read(:cross_region_scan)
        |> Ash.Query.filter(region in ^regions)
        |> Ash.read!()

      {:ok, rows}
    end
  end
end
