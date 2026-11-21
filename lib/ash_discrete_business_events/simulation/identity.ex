# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Simulation.Identity do
  @domain_tag "ash_discrete_business_events.simulation.identity.v1"

  @known_keys [:subject, :random_stream_id, :replication_id]

  @moduledoc """
  The common-random-numbers identity of a simulated run: `seed/1` maps
  `(subject, random_stream_id, replication_id)` to an unsigned 64-bit
  seed and `draw/1` reads a float in `[0.0, 1.0)` off that seed.

  Two simulated candidates that are compared must draw the same random
  numbers for the same subject, stream and replication, so a difference
  between them comes from the candidate and not from the dice. The seed
  is therefore a pure function of exactly those three inputs: a
  candidate id, a snapshot digest or a model hash is refused as an
  unknown key, and a missing `random_stream_id` is never defaulted.

  The output is stable across releases: the first 8 bytes of a SHA-256
  over a versioned domain tag and the length-prefixed inputs. Changing
  the tag or the encoding is a breaking change of every recorded
  comparison, because it re-rolls every recorded run.

  No statistical quality is claimed beyond SHA-256 output being
  uniform; this module decides which numbers a run sees, it is not a
  generator of them.

  ## Example

      seed(subject: "subject-1", random_stream_id: "arrivals", replication_id: 0)
      #=> 7_051_631_904_854_280_433

      draw(subject: "subject-1", random_stream_id: "arrivals", replication_id: 0)
      #=> 0.3822697315405553
  """

  @typedoc "A subject key; a non-empty binary is accepted at runtime."
  @type subject :: binary()
  @type random_stream_id :: binary()
  @type replication_id :: non_neg_integer()

  @spec seed(keyword() | map()) :: non_neg_integer()
  def seed(opts) do
    {subject, random_stream_id, replication_id} = normalize(opts)

    :crypto.hash(:sha256, identity_data(subject, random_stream_id, replication_id))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
  end

  @spec draw(keyword() | map()) :: float()
  def draw(opts) do
    Bitwise.bsr(seed(opts), 11) / 9_007_199_254_740_992
  end

  defp identity_data(subject, random_stream_id, replication_id) do
    [
      <<byte_size(@domain_tag)::unsigned-64, @domain_tag::binary>>,
      <<byte_size(subject)::unsigned-64, subject::binary>>,
      <<byte_size(random_stream_id)::unsigned-64, random_stream_id::binary>>,
      <<replication_id::unsigned-64>>
    ]
  end

  defp normalize(opts) when is_list(opts) do
    Enum.each(opts, fn
      {key, _value} when is_atom(key) -> :ok
      other -> raise ArgumentError, "expected keyword options, got: #{inspect(other)}"
    end)

    keys = for {key, _value} <- opts, do: key
    normalize_keys(opts, keys)
  end

  defp normalize(opts) when is_map(opts) do
    normalize_keys(opts, Map.keys(opts))
  end

  defp normalize(opts) do
    raise ArgumentError,
          "expected a keyword list or a map of :subject, :random_stream_id and " <>
            ":replication_id, got: #{inspect(opts)}"
  end

  defp normalize_keys(opts, keys) do
    case Enum.find(keys, &(&1 not in @known_keys)) do
      nil -> :ok
      key -> raise ArgumentError, unknown_key_message(key)
    end

    case duplicate_key(keys) do
      nil -> :ok
      key -> raise ArgumentError, "duplicate key #{inspect(key)} — each key may appear once"
    end

    Enum.each(@known_keys, fn key ->
      case fetch(opts, key) do
        {:ok, _value} -> :ok
        :error -> raise ArgumentError, "missing required key :#{key} — it is never defaulted"
      end
    end)

    {require_binary(opts, :subject), require_binary(opts, :random_stream_id),
     require_replication_id(opts, :replication_id)}
  end

  defp unknown_key_message(key) do
    "unknown key #{inspect(key)} — the identity takes only :subject, " <>
      ":random_stream_id and :replication_id"
  end

  defp duplicate_key(keys) do
    keys
    |> Enum.frequencies()
    |> Enum.find(fn {_key, count} -> count > 1 end)
    |> case do
      nil -> nil
      {key, _count} -> key
    end
  end

  defp fetch(opts, key) when is_list(opts), do: Keyword.fetch(opts, key)
  defp fetch(opts, key) when is_map(opts), do: Map.fetch(opts, key)

  defp require_binary(opts, key) do
    case fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              ":#{key} must be a non-empty binary, got: #{inspect(value)}"
    end
  end

  defp require_replication_id(opts, key) do
    case fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              ":#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
