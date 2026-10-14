# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Mappings do
  @moduledoc """
  The mapping engine's public seam: publish declared mappings into
  versioned artifacts, and apply active artifacts to raw payloads.

      # Publish the declared mapping into its versioned resource
      # (draft → validate → activate — the snapshot lifecycle):
      {:ok, version} =
        AshDiscreteBusinessEvents.Mappings.publish(
          MyApp.BusinessEvents,               # the DSL host module
          :opportunity_stage_changed,         # the mapping name
          MyApp.Platform.MappingVersion
        )

      version = AshDiscreteBusinessEvents.Mappings.activate!(version)

      # Apply an active version to a raw payload — pure, deterministic:
      {:ok, canonical} =
        AshDiscreteBusinessEvents.Mappings.run(version, raw_payload,
          source_record_id: source_record.id
        )

      MyApp.Platform.Ledger.record!(%{
        event_kind: canonical.event_kind,
        occurred_at: canonical.occurred_at,
        provenance: canonical.provenance,
        data: canonical.data,
        ...
      })

  `canonical.provenance` is the ledger's provenance, ready-made: the
  `mapping_name` + `mapping_version_hash` pair joins exactly to the
  active `MappingVersion` row, so any ledger row points back into
  replayable data rather than a code revision (§5.3).
  """

  alias AshDiscreteBusinessEvents.Info
  alias AshDiscreteBusinessEvents.Mappings.Compiler

  @doc """
  Compiles the declared mapping `name` on `host` and records it as a
  `MappingVersion` draft on `mapping_version_resource`.

  Content-addressed: publishing an unchanged declaration returns the
  existing version (the hash IS the identity); a changed declaration
  mints a NEW version row — history is never overwritten.
  """
  @spec publish(module(), atom(), module()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def publish(host, mapping_name, mapping_version_resource)
      when is_atom(host) and is_atom(mapping_name) and is_atom(mapping_version_resource) do
    mapping = Info.mapping(host, mapping_name)

    case mapping do
      nil ->
        {:error, "no declared mapping #{inspect(mapping_name)} on #{inspect(host)}"}

      mapping ->
        {artifact, hash} = Compiler.compile(mapping)

        case existing(mapping_version_resource, mapping_name, hash) do
          # read_one hands back {:ok, nil} when there is no row — only a
          # real record means "already published".
          {:ok, version} when not is_nil(version) ->
            {:ok, version}

          _ ->
            [source_name, stream_name] = artifact["source"]

            # The STORED artifact is the hash's input, verbatim — the
            # invariant version_hash == Compiler.hash(artifact) is what
            # replay-proof and provenance joins stand on.
            mapping_version_resource
            |> Ash.Changeset.for_create(:draft, %{
              mapping_name: artifact["mapping_name"],
              version_hash: hash,
              source_name: String.to_existing_atom(source_name),
              stream_name: String.to_existing_atom(stream_name),
              artifact: artifact
            })
            |> Ash.create()
        end
    end
  end

  @doc "The active `MappingVersion` for a mapping name, or nil."
  @spec active_version(module(), atom()) :: Ash.Resource.record() | nil
  def active_version(mapping_version_resource, mapping_name) do
    mapping_version_resource
    |> Ash.Query.for_read(:active, %{mapping_name: to_string(mapping_name)})
    |> Ash.read_one()
    |> case do
      {:ok, version} -> version
      _ -> nil
    end
  end

  @doc "Marks a validated version active, superseding the name's previous active."
  @spec activate!(Ash.Resource.record()) :: Ash.Resource.record()

  def activate!(%{status: :validated} = version), do: Ash.update!(version, %{}, action: :activate)

  def activate!(version) do
    raise ArgumentError,
          "only a :validated version can activate; got status #{inspect(version.status)} " <>
            "(run :validate first — the lifecycle is draft → validate → activate)"
  end

  @doc """
  Applies an active version (or any artifact) to a raw payload. Pure —
  see `Mappings.Compiler.run/3` for the contract.
  """
  defdelegate run(version_or_artifact, payload, opts \\ []), to: Compiler

  defp existing(resource, mapping_name, hash) do
    resource
    |> Ash.Query.for_read(:by_name_and_hash, %{
      mapping_name: to_string(mapping_name),
      version_hash: hash
    })
    |> Ash.read_one()
  end
end
