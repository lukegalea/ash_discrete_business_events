# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Record do
  @moduledoc """
  The `:record` action's run module — the ledger's only write path.

  Delivery idempotency: a `delivery_key` already recorded IN THE SAME
  REGION collapses to the existing row. The fast path is an unlocked
  read (webhook retries are common and read-only); the racy path is
  covered by the `(delivery_key, region)` identity — the region lock
  serializes same-region writers, and if two writers for one delivery
  key race past the fast path, the unique index rejects the loser and
  this module re-reads and returns the winner. Either way: one row per
  delivery, per region.

  ## The caller's context reaches the append

  The actor, tenant, `authorize?` flag and tracer the `record` call was
  made with are passed on to the internal `:append` and to the delivery
  lookup (`Ash.Context.to_opts/1`). A host whose ledger is multitenant
  needs the tenant on the insert; a host whose policies govern `:append`
  needs the actor there, and a host that records as machinery
  (`authorize?: false`) must not have the inner write re-authorized
  without an actor. Without this the inner calls ran with no actor and
  no tenant, whatever the caller said.
  """

  use Ash.Resource.Actions.Implementation

  @appended ~w(region residency_tag subject_type subject_external_id subject_stream
               actor_type actor_external_id actor_display occurred_at observed_at context
               provenance supersedes_event_id delivery_key data)a

  require Ash.Query

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    args = input.arguments
    opts = Ash.Context.to_opts(context)

    case delivered_already(resource, args, opts) do
      {:ok, existing} when not is_nil(existing) ->
        # Already delivered: collapse to the existing row. Nothing is
        # written, no sequence is consumed, no chain link is spent.
        {:ok, existing}

      _ ->
        append(resource, args, opts)
    end
  end

  defp append(resource, args, opts) do
    # Optional arguments a caller left out are absent from `args`, not
    # nil, so every column is read with Map.take; nils are dropped below.
    append_attrs = Map.take(args, @appended)

    sim_extra =
      if Map.has_key?(args, :simulation_run),
        do: %{simulation_run: args.simulation_run},
        else: %{}

    append_attrs =
      append_attrs
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(%{
        event_kind: args.event_kind,
        subject_resource: Map.get(args, :subject_resource)
      })

    changeset =
      resource
      |> Ash.Changeset.for_create(:append, Map.merge(append_attrs, sim_extra), opts)

    case Ash.create(changeset) do
      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        retry_on_delivery_race(error, resource, args, opts)
    end
  end

  # Lost the race against a concurrent writer for the same delivery key
  # (same region): the unique index rejected our append — return the
  # winner instead of an error. Any other error passes through.
  defp retry_on_delivery_race(error, resource, args, opts) do
    delivered? =
      Map.get(args, :delivery_key) != nil and
        Exception.message(error) =~ "has already been delivered"

    if delivered? do
      case delivered_already(resource, args, opts) do
        {:ok, existing} when not is_nil(existing) -> {:ok, existing}
        _ -> {:error, error}
      end
    else
      {:error, error}
    end
  end

  defp delivered_already(resource, args, opts) do
    case Map.get(args, :delivery_key) do
      delivery_key when is_binary(delivery_key) ->
        resource
        |> Ash.Query.for_read(:by_region, %{region: args.region}, opts)
        |> Ash.Query.filter(delivery_key == ^delivery_key)
        |> Ash.read_one()

      _ ->
        {:ok, nil}
    end
  end
end
