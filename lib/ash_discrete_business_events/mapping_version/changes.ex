# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.MappingVersion.Changes do
  @moduledoc """
  The lifecycle's changes: `ValidateStoredArtifact` (the `:validate`
  action's work) and `ActivateSuperseding` (the `:activate` action's
  pointer move).
  """

  alias AshDiscreteBusinessEvents.Mappings.Compiler

  defmodule ValidateStoredArtifact do
    @moduledoc """
    Re-runs the compiler's structural checks over the STORED artifact —
    not the declaration. The row is the thing provenance points at, so
    validation proves the row: a hand-edited or drifted artifact fails
    here, loudly, instead of quietly disagreeing with the compiler.
    """

    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        case Compiler.verify(Ash.Changeset.get_attribute(changeset, :artifact)) do
          :ok ->
            changeset

          {:error, problems} ->
            Ash.Changeset.add_error(
              changeset,
              AshDiscreteBusinessEvents.MappingVersion.InvalidArtifact.exception(
                message: Enum.join(problems, "; ")
              )
            )
        end
      end)
    end
  end

  defmodule ActivateSuperseding do
    @moduledoc """
    Supersedes the mapping name's previous active version (demoted to
    `:validated` — activation is the pointer move, not history). One
    active version per mapping name: the ledger's provenance
    (mapping_name + mapping_version_hash) must resolve to exactly one
    row.
    """

    use Ash.Resource.Change

    require Ash.Query

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        resource = changeset.resource
        name = Ash.Changeset.get_attribute(changeset, :mapping_name)

        resource
        |> Ash.Query.filter(mapping_name == ^name and status == :active)
        |> Ash.read!()
        |> Enum.each(fn previous ->
          previous
          |> Ash.Changeset.for_update(:demote, %{})
          |> Ash.update!()
        end)

        changeset
      end)
    end
  end
end
