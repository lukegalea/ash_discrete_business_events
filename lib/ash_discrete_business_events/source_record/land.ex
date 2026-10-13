# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.SourceRecord.Land do
  @moduledoc """
  The `:land` action's run module — the read-decide-write behind
  idempotent raw landing (design §1.3, §2.5).

  The decision compares against the version valid **at `fetched_at`**
  (`as_of = fetched_at`), not against the current head: a late-arriving
  duplicate of already-observed content must be a no-op, not a new
  period. Identical means payload AND cursor equal — the cursor rides
  the observation, so a fresh cursor on unchanged content is still a
  write (a new version carrying the advanced cursor). Payload equality
  is JSON-canonicalizing (the storage round-trip), so atom-keyed and
  string-keyed maps that decode alike are the same observation.

  Landing an observation whose `fetched_at` precedes the identity's
  known history is refused, loudly (taps deliver in cursor order; the
  design's backdated-import reconstruction, §4, is BIZEV-9's work).
  """

  use Ash.Resource.Actions.Implementation

  alias AshDiscreteBusinessEvents.SourceRecord.BackdatedLanding

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    args = input.arguments
    fetched_at = args.fetched_at

    # The internal reads/writes inherit the CALLER's authorization: the
    # host's :land action is the policy gate, and these inner calls run
    # under the same actor/tenant/authorize? decision — never a bare
    # nil-actor read that grant-filter policies would silently narrow to
    # nothing (which would misread "identity unseen" and open an
    # overlapping period).
    auth = [
      actor: context.actor,
      tenant: context.tenant,
      authorize?: Map.get(context, :authorize?, true)
    ]

    run_inner(resource, args, fetched_at, auth)
  end

  defp run_inner(resource, args, fetched_at, auth) do

    case current_version_at(resource, args, fetched_at, auth) do
      {:ok, nil} ->
        # No version contains the instant: either the identity has never
        # landed (open its first period) or the instant precedes known
        # history (refuse — see `guard_backdated/4`).
        open_first_period(resource, args, fetched_at, auth)

      {:ok, record} ->
        if identical?(record, args) do
          # The VPM-49 import-rework pattern: re-observing identical
          # content writes nothing and returns what is already there.
          {:ok, record}
        else
          replace_observation(record, args, fetched_at, auth)
        end
    end
  end

  defp current_version_at(resource, args, fetched_at, auth) do
    resource
    |> Ash.Query.for_read(:by_identity, %{
      source: args.source,
      stream: args.stream,
      external_id: args.external_id,
      region: args.region
    })
    |> Ash.Query.as_of(fetched_at)
    |> Ash.read_one(auth)
  end

  defp open_first_period(resource, args, fetched_at, auth) do
    with :ok <- guard_backdated(resource, args, fetched_at, auth) do
      changeset =
        resource
        |> Ash.Changeset.for_create(:open_period, %{
          source: args.source,
          stream: args.stream,
          external_id: args.external_id,
          region: args.region,
          residency_tag: args.residency_tag,
          raw_payload: args.raw_payload,
          source_metadata: Map.get(args, :source_metadata),
          cursor: Map.get(args, :cursor),
          fetched_at: fetched_at
        })
        |> Ash.Changeset.as_of(fetched_at)

      Ash.create(changeset, auth)
    end
  end

  # On the nil-at-instant path, the only way the identity already exists
  # is a version whose period begins AFTER the observation instant — the
  # identity's head start. Refuse before writing, so the operator sees
  # the ruling rather than a naked exclusion-constraint violation.
  defp guard_backdated(resource, args, fetched_at, auth) do
    case head_start(resource, args, auth) do
      {:ok, nil} ->
        :ok

      {:ok, %{valid_at: head_period}} ->
        if DateTime.compare(head_period.lower, fetched_at) == :gt do
          {:error,
           BackdatedLanding.exception(
             message:
               "cannot land an observation at #{DateTime.to_iso8601(fetched_at)} earlier " <>
                 "than the identity's known history (its current period begins " <>
                 "#{DateTime.to_iso8601(head_period.lower)}): " <>
                 inspect({args.source, args.stream, args.external_id, args.region}) <>
                 ". Taps deliver in cursor order; the backdated-import " <>
                 "reconstruction (design §4) is the corrections slice's work."
           )}
        else
          :ok
        end
    end
  end

  defp head_start(resource, args, auth) do
    resource
    |> Ash.Query.for_read(:by_identity, %{
      source: args.source,
      stream: args.stream,
      external_id: args.external_id,
      region: args.region
    })
    |> Ash.read_one(auth)
  end

  defp replace_observation(record, args, fetched_at, auth) do
    record
    |> Ash.Changeset.for_update(:replace_observation, %{
      raw_payload: args.raw_payload,
      source_metadata: Map.get(args, :source_metadata),
      cursor: Map.get(args, :cursor),
      fetched_at: fetched_at
    })
    |> Ash.Changeset.as_of(fetched_at)
    |> Ash.update(auth)
  end

  defp identical?(record, args) do
    json_normalize(record.raw_payload) == json_normalize(args.raw_payload) and
      json_normalize(record.cursor) == json_normalize(Map.get(args, :cursor))
  end

  # JSON-canonicalizing normalization: the stored payload came back
  # through jsonb (string-keyed), so the incoming observation is compared
  # through the same round-trip. Atom keys that decode alike are the same
  # content; key order is not.
  defp json_normalize(nil), do: nil
  defp json_normalize(value), do: value |> Jason.encode!() |> Jason.decode!()
end
