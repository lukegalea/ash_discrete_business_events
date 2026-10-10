# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Changes.StampEvent do
  @moduledoc """
  The ledger's write-path change, on the internal `:append` create:

  1. **Takes the per-region advisory xact lock** (via
     `RegionLockKeyGenerator`, the same behaviour ash_events uses for its
     own audit lock) — before the insert, in the same transaction, so
     bigserial `sequence` order is commit order per region (the three
     caveats live on the generator's moduledoc, and the concurrent
     writers test pins them).
  2. **Stamps the AshEvents machinery fields** from the business-event
     inputs: `action` rides the event kind (§5.1 — the projector DSL's
     `project "kind"` matches the atom form, converted at compile
     time), `action_type` is `:create` (every business event is a new
     fact, corrections included — they are new rows), `resource` carries
     the subject type's atom form for replay routing (default
     `:"bizev.event"` until a host wires consumers), and `record_id`
     carries the subject's external id (the id of the thing the event is
     about — `record_id_type :string`). `observed_at` is the attribute
     default (the write's clock).

  The hash chain is NOT here: it is a `BEFORE INSERT` trigger
  (`ChainSQL`), piggybacking on this change's lock — no new
  serialization.
  """

  use Ash.Resource.Change

  @default_subject_resource :"bizev.event"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &lock_and_stamp/1)
  end

  defp lock_and_stamp(changeset) do
    changeset
    |> take_region_lock()
    |> stamp_machinery_fields()
  end

  defp take_region_lock(changeset) do
    repo = AshPostgres.DataLayer.Info.repo(changeset.resource)
    generator = AshEvents.EventLog.Info.event_log_advisory_lock_key_generator!(changeset.resource)

    case generator.generate_key!(changeset, nil) do
      [key1, key2] ->
        Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_xact_lock($1, $2)", [key1, key2])
        changeset

      key when is_integer(key) ->
        Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_xact_lock($1)", [key])
        changeset
    end
  end

  defp stamp_machinery_fields(changeset) do
    kind = Ash.Changeset.get_argument(changeset, :event_kind)
    subject_resource = Ash.Changeset.get_argument(changeset, :subject_resource)

    # force_change_attributes: the machinery fields are stamped in
    # before_action, after validation — they are not caller input by
    # design (nothing can record an event with a forged `action_type`).
    Ash.Changeset.force_change_attributes(changeset, %{
      action: kind,
      action_type: action_type_for(kind, subject_resource),
      resource: subject_resource || @default_subject_resource,
      record_id: Ash.Changeset.get_attribute(changeset, :subject_external_id),
      version: 1
    })
  end

  # action_type is the substrate's REPLAY ROUTING: how the event
  # re-applies to its subject resource. Business events are create-facts
  # (:create by default), but when a host wires a consumer resource
  # (subject_resource) whose action of the kind's name is an update,
  # the event must replay as one. The default subject has no actions —
  # its events are always :create.
  defp action_type_for(_kind, nil), do: :create
  defp action_type_for(_kind, @default_subject_resource), do: :create

  defp action_type_for(kind, subject_resource) do
    case Ash.Resource.Info.action(subject_resource, kind) do
      %{type: type} when type in [:create, :update, :destroy] -> type
      _ -> :create
    end
  end
end
