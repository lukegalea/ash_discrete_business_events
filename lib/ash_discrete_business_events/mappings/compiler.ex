# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Mappings.Compiler do
  @moduledoc """
  The mapping engine's pure core: artifact construction, content
  hashing, structural verification, and the apply path.

  Everything here is a pure function of its inputs — no clocks, no
  actors, no I/O. The same artifact over the same payload yields the
  same canonical fields, always; that is what makes rule-version-pinned
  replay a property of the engine and not a discipline of its callers
  (design §2.2).

  The content hash covers the operators in DECLARATION ORDER (ora-3
  §13.3): the canonical form serializes the ops as a LIST, and a JSON
  map's key order is irrelevant while a list's is not. Two mappings
  whose operators differ only in order hash differently — the order of
  the rules is part of the rule.
  """

  alias AshDiscreteBusinessEvents.Dsl.Mapping

  @hash_bytes 8
  @occurred_at_target "occurred_at"
  @datetime_types [:utc_datetime_usec, :utc_datetime, :datetime]

  # ── artifact ───────────────────────────────────────────────────────────

  @doc """
  The canonical artifact for a declared mapping — the form that is
  hashed, stored on a `MappingVersion`, and applied.
  """
  @spec artifact(Mapping.t()) :: map()
  def artifact(%Mapping{} = mapping) do
    %{
      "mapping_name" => Atom.to_string(mapping.name),
      "source" => mapping.source |> Tuple.to_list() |> Enum.map(&Atom.to_string/1),
      "ops" => Enum.map(mapping.ops, &op_canonical/1)
    }
    |> put_value("classify_with", mapping.classify_with && Atom.to_string(mapping.classify_with))
  end

  defp op_canonical(op) do
    %{"op" => Atom.to_string(op.op), "target" => Atom.to_string(op.target)}
    |> put_value("from", op.from)
    |> put_value("type", op.type && Atom.to_string(op.type))
    |> put_value("cases", op.cases)
    |> put_value("default", op.default)
    |> put_value("separator", op.separator)
    |> put_value("value", op.value)
    |> put_value("reason", op.reason)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The content hash of an artifact — the first #{@hash_bytes} hex chars of
  its SHA-256, the form the ledger's `mapping_version_hash` provenance
  carries.

  Raises `ArgumentError` on non-JSON terms: an artifact must hash
  deterministically, and atoms in operator values would encode
  node-local state.
  """
  @spec hash(map()) :: String.t()
  def hash(artifact) when is_map(artifact) do
    :crypto.hash(:sha256, Jason.encode!(artifact))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_bytes)
  end

  @doc "Convenience: artifact + hash for a declared mapping."
  @spec compile(Mapping.t()) :: {map(), String.t()}
  def compile(%Mapping{} = mapping) do
    artifact = artifact(mapping)
    {artifact, hash(artifact)}
  end

  # ── structural verification (re-runnable over a STORED artifact) ──────

  @doc """
  Re-runs the compiler's structural checks over an artifact — the
  `:validate` lifecycle action's work. `:ok`, or `{:error, problems}`
  (a list of strings).

  These are the checks that survive storage: duplicate target keys
  (refused by name), empty path/case lists, nil-adjacent footguns, and
  the occurred-vs-observed discipline — every mapping extracts
  `occurred_at` as a datetime.
  """
  @spec verify(map()) :: :ok | {:error, [String.t()]}
  def verify(artifact) when is_map(artifact) do
    ops = artifact["ops"] || []

    problems =
      Enum.concat([
        duplicate_target_problems(ops),
        occurred_at_problems(ops),
        Enum.flat_map(ops, &op_problems/1)
      ])

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp duplicate_target_problems(ops) do
    ops
    |> Enum.group_by(fn op -> op["target"] end)
    |> Enum.flat_map(fn
      {target, group} when length(group) > 1 ->
        named = Enum.map_join(group, ", ", &"#{&1["op"]} (op #{position(ops, &1)})")

        [
          "redundant operators: target `#{target}` is written by #{named} — " <>
            "refused by name; merge or remove all but one"
        ]

      {_target, _singleton} ->
        []
    end)
  end

  defp occurred_at_problems(ops) do
    extraction =
      Enum.find(ops, fn op ->
        op["target"] == @occurred_at_target && op["op"] in ["map", "decode", "constant"]
      end)

    cond do
      extraction == nil ->
        [
          "no occurred_at extraction: every mapping must extract the source's truth " <>
            "time from the payload (§1.3 — map/decode/constant with target " <>
            "`occurred_at` and a datetime type)"
        ]

      not (extraction["type"] && Atom.to_string(extraction["type"]) in datetime_strings()) ->
        [
          "occurred_at extraction must have a datetime type " <>
            "(#{Enum.join(datetime_strings(), ", ")}); got #{inspect(extraction["type"])}"
        ]

      true ->
        []
    end
  end

  defp datetime_strings, do: Enum.map(@datetime_types, &Atom.to_string/1)

  defp op_problems(op) do
    empty = op["from"] in [nil, []]

    List.wrap(
      cond do
        op["op"] == "coalesce" and empty ->
          "coalesce on `#{op["target"]}` has no paths"

        op["op"] == "concat" and empty ->
          "concat on `#{op["target"]}` has no paths"

        op["op"] == "decode" and op["cases"] in [nil, %{}] ->
          "decode on `#{op["target"]}` has no cases — a translation table that " <>
            "translates nothing is a footgun; use map or unmapped_because"

        op["op"] == "unmapped_because" and op["target"] == @occurred_at_target ->
          "occurred_at cannot be declared unmapped — the occurred-vs-observed " <>
            "discipline requires its extraction (§1.3)"

        true ->
          nil
      end
    )
  end

  # ── the apply path ─────────────────────────────────────────────────────

  @doc """
  Applies an artifact (or a stored `MappingVersion`'s artifact) to a raw
  SourceRecord payload: pure, deterministic, clock-free (observed time is
  the WRITE's business, never the mapping's).

  Returns:

    * `{:ok, canonical}` — `canonical` carries `:event_kind` (the
      mapping name, the kind), `:data` (the written targets —
      `occurred_at` excluded, it has its own ledger column),
      `:occurred_at` (the extracted source truth time),
      `:provenance` (mapping_name + mapping_version_hash + the caller's
      `:source_record_id` — the ledger row's provenance, ready-made),
      and `:unmapped` (the `unmapped_because` declarations, refusal by
      name).
    * `{:ok, :skipped, reason}` — the classifier seam declined the
      record.
    * `{:error, term}` — a decode miss, a cast failure, or a payload
      without the occurred_at extraction.

  Options: `:source_record_id` (provenance), `:classifier` (a
  `AshDiscreteBusinessEvents.Mappings.Classifier` implementation — the
  artifact may name one; the option wins), `:payload` passthrough for
  classifiers is the payload itself.
  """
  @spec apply(map(), map(), keyword()) ::
          {:ok, map()} | {:ok, :skipped, String.t()} | {:error, term()}
  def run(artifact, payload, opts \\ [])

  def run(%{artifact: artifact}, payload, opts) when is_map(artifact) do
    run(artifact, payload, opts)
  end

  def run(artifact, payload, opts) when is_map(artifact) and is_map(payload) do
    with :ok <- verify(artifact),
         {:ok, fields} <- run_ops(artifact, payload),
         {:ok, canonical} <- occurred_at_from(fields, artifact),
         {:ok, canonical} <- classify(artifact, payload, canonical, opts) do
      {:ok, canonical}
    end
  end

  defp run_ops(artifact, payload) do
    ops = artifact["ops"] || []

    unmapped =
      ops
      |> Enum.filter(&(&1["op"] == "unmapped_because"))
      |> Map.new(&{&1["target"], &1["reason"]})

    Enum.reduce_while(ops, {:ok, %{}}, fn op, {:ok, acc} ->
      case eval_op(op, payload) do
        {:write, value} ->
          target = op["target"]

          {:cont,
           {:ok,
            if target == @occurred_at_target do
              Map.put(acc, @occurred_at_target, value)
            else
              Map.put(acc, target, value)
            end}}

        :skip ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, "operator #{op["op"]} (#{op["target"]}) failed: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, {fields, unmapped}}
      other -> other
    end
  end

  defp occurred_at_from({fields, unmapped}, artifact) do
    case Map.fetch(fields, @occurred_at_target) do
      {:ok, %DateTime{} = occurred_at} ->
        {:ok,
         %{
           event_kind: String.to_existing_atom(artifact["mapping_name"]),
           data: Map.delete(fields, @occurred_at_target),
           occurred_at: occurred_at,
           provenance: %{
             "mapping_name" => artifact["mapping_name"],
             "mapping_version_hash" => artifact["version_hash"] || hash(artifact),
             "source_record_id" => nil
           },
           unmapped: unmapped
         }}

      {:ok, other} ->
        {:error, "occurred_at extraction did not yield a datetime: #{inspect(other)}"}

      :error ->
        {:error, :no_occurred_at}
    end
  end

  defp eval_op(op, payload) do
    case op["op"] do
      "map" -> write(op, fetch_path(payload, op["from"]), &cast(&1, type(op)))
      "decode" -> decode(op, payload)
      "coalesce" -> coalesce(op, payload)
      "concat" -> concat(op, payload)
      "constant" -> write(op, {:ok, op["value"]}, &cast(&1, type(op)))
      "unmapped_because" -> :skip
    end
  end

  defp write(op, {:ok, nil}, _cast), do: {:write, nil} |> skip_nil(op)
  defp write(op, {:ok, value}, cast), do: cast.(value) |> to_write(op)
  defp write(_op, {:error, reason}, _cast), do: {:error, reason}

  defp skip_nil({:write, nil}, op) do
    if is_nil(op["default"]), do: :skip, else: {:write, op["default"]}
  end

  defp skip_nil(write, _op), do: write

  defp to_write({:ok, value}, _op), do: {:write, value}
  defp to_write({:error, reason}, op), do: {:error, "#{op["target"]}: #{reason}"}

  defp type(op), do: op["type"] && String.to_atom(op["type"])

  defp decode(op, payload) do
    source_value = fetch_path(payload, op["from"])

    cond do
      is_nil(source_value) and not is_nil(op["default"]) ->
        write(op, {:ok, op["default"]}, &cast(&1, type(op)))

      is_nil(source_value) ->
        :skip

      true ->
        key = json_key(source_value)

        case op["cases"] do
          %{^key => canonical_value} ->
            write(op, {:ok, canonical_value}, &cast(&1, type(op)))

          _ ->
            {:error, "no case for source value #{inspect(source_value)}"}
        end
    end
  end

  defp coalesce(op, payload) do
    value = Enum.find_value(op["from"], &fetch_path(payload, &1))

    if is_nil(value), do: :skip, else: {:write, value}
  end

  defp concat(op, payload) do
    parts =
      op["from"]
      |> Enum.map(&fetch_path(payload, &1))
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      :skip
    else
      {:write, Enum.map(parts, &to_string/1) |> Enum.join(op["separator"] || " ")}
    end
  end

  # Payload paths are dot-separated strings over string-keyed JSON (the
  # SourceRecord's raw payload is exactly what the source emitted).
  defp fetch_path(payload, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(payload, fn segment, acc ->
      case acc do
        %{^segment => value} -> value
        _ -> nil
      end
    end)
  end

  # Decode case keys are JSON terms; lookups canonicalize through the
  # JSON round-trip so `"1"` and 1 hit the same case.
  defp json_key(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _ -> to_string(value)
    end
  end

  defp cast(nil, _type), do: {:ok, nil}

  defp cast(value, type) when is_atom(type) do
    case Ash.Type.cast_input(type, value, []) do
      {:ok, casted} -> {:ok, casted}
      {:error, error} -> {:error, "cast to #{type} failed: #{inspect(error)}"}
    end
  end

  # ── the classifier seam ────────────────────────────────────────────────

  defp classify(artifact, payload, canonical, opts) do
    classifier = opts[:classifier] || artifact["classify_with"] && String.to_atom(artifact["classify_with"])

    if classifier do
      canonical = put_in(canonical.provenance["source_record_id"], opts[:source_record_id])

      case classifier.classify(artifact, payload, canonical) do
        :emit -> {:ok, canonical}
        {:emit, kind} when is_atom(kind) -> {:ok, %{canonical | event_kind: kind}}
        {:skip, reason} -> {:ok, :skipped, reason}
        {:error, reason} -> {:error, {:classifier, reason}}
        other -> {:error, {:classifier, {:invalid_return, other}}}
      end
    else
      canonical =
        canonical
        |> put_in(
          [:provenance, "source_record_id"],
          opts[:source_record_id]
        )

      {:ok, canonical}
    end
  end

  defp position(ops, op), do: Enum.find_index(ops, &(&1 == op)) + 1

  defp put_value(map, _key, nil), do: map
  defp put_value(map, key, value), do: Map.put(map, key, value)
end
