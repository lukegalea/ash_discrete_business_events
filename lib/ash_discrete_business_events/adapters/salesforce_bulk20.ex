# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.SalesforceBulk20 do
  @moduledoc """
  The Salesforce Bulk API 2.0 adapter (§7) — the first real vertical.

  Bulk 2.0 gives **state snapshots cursorable by `SystemModstamp`, not an
  event feed**: each sync runs one query job over
  `WHERE SystemModstamp > <cursor> ORDER BY SystemModstamp`, downloads
  the results, and the RAW LAYER's periods become the version
  transitions — the discrete events are derived by mapping, never
  invented here.

  ## Budget as data (§7)

  Every transport call is accounted against the source's `rate_budget`
  (e.g. `[daily: 250_000]`, the org's daily API budget). Exhaustion
  raises `AshDiscreteBusinessEvents.Adapters.BudgetExhausted` — the job
  FAILs visibly, lineage records it, and the feed PAUSES (the cursor
  stands where the last completed batch ended); it does not degrade by
  silently skipping or truncating.

  ## PK-chunking awareness

  Large result sets come back as multiple result sets (PK chunks). The
  download fetches every chunk — each an accounted API call — so a
  chunked job costs more budget than a plain one and the accounting is
  honest about it.

  ## The auth edge (ADR 0011)

  The adapter never fetches tokens. `conn` — the transport's connection
  (`%{instance_url:, token:}`) — arrives from the configured
  `AshDiscreteBusinessEvents.Adapters.AuthProvider` via the sync runner.
  A connection id is never an action argument; a test double stands in
  for Nango in CI (no live Nango dependency).
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  alias AshDiscreteBusinessEvents.Adapters.BudgetExhausted

  @cursor_field "SystemModstamp"
  @calls_per_batch 3
  @poll_attempts 120

  @doc """
  The transport for this adapter — the `:salesforce_bulk20_transport`
  application env, defaulting to the Req wiring (live-shaped, CI uses
  the fixture-corpus transport).
  """
  @spec transport() :: module()
  def transport do
    Application.get_env(
      :ash_discrete_business_events,
      :salesforce_bulk20_transport,
      AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.ReqTransport
    )
  end

  @impl true
  def cursor_field(_stream), do: @cursor_field

  @impl true
  def api_calls_per_batch, do: @calls_per_batch

  @impl true
  def fetch_batch(source, stream, conn, cursor, opts) do
    transport = Keyword.get(opts, :transport, transport())
    calls_used = Keyword.get(opts, :api_calls_used, 0)
    limit = Keyword.get(opts, :limit)
    budget = budget(source)

    soql = soql(stream, cursor, limit)

    # Two certain spends per batch: the job create and the results
    # download (PK-chunked downloads spend extra retrieves — accounted).
    with :ok <- budget_check(budget, calls_used, 1),
         {:ok, job_id} <- transport.create_query_job(conn, soql, opts),
         :ok <- poll_until_complete(transport, conn, job_id),
         :ok <- budget_check(budget, calls_used, 2),
         {:ok, %{records: records, pk_chunked?: chunked?}} <-
           transport.download_results(conn, job_id, opts) do
      records = maybe_limit(records, limit)
      next_cursor = next_cursor(records, cursor)

      {:ok,
       %{
         records: records,
         next_cursor: next_cursor,
         complete?: complete?(records, limit),
         pk_chunked?: chunked?,
         api_calls_used: calls_used + calls_spent(chunked?)
       }}
    end
  end

  # The stream's `select` is the SOQL declaration; the cursor filter is
  # appended (the declared select must not carry its own WHERE — the
  # cursoring is the adapter's job).
  defp soql(stream, cursor, limit) do
    base = String.trim(stream.select || "")

    base =
      if cursor == nil or cursor == %{} do
        base
      else
        field = @cursor_field
        value = Map.get(cursor, field)
        "#{base} WHERE #{field} > #{soql_literal(value)}"
      end

    base = "#{base} ORDER BY #{@cursor_field}"

    case limit do
      nil -> base
      n -> "#{base} LIMIT #{n}"
    end
  end

  # SystemModstamp literals are SOQL datetimes, single-quoted ISO.
  defp soql_literal(%DateTime{} = dt), do: "'" <> DateTime.to_iso8601(dt) <> "'"
  defp soql_literal(value) when is_binary(value), do: "'" <> value <> "'"
  defp soql_literal(value), do: to_string(value)

  defp poll_until_complete(transport, conn, job_id) do
    # Polls are capped by attempts, not budgeted individually: the two
    # certain spends (create + download) are the budgeted units.
    Enum.reduce_while(1..@poll_attempts, :ok, fn _attempt, :ok ->
      case transport.job_state(conn, job_id, []) do
        {:ok, :completed} -> {:halt, :ok}
        {:ok, :in_progress} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # PK-chunked downloads spend extra retrieve calls — accounted.
  defp calls_spent(true), do: 4
  defp calls_spent(false), do: 2

  defp budget(source) do
    case source.rate_budget[:daily] do
      nil -> nil
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp budget_check(nil, _calls_used, _pending), do: :ok

  defp budget_check(budget, calls_used, pending) do
    if calls_used + pending > budget do
      {:error,
       BudgetExhausted.exception(
         message:
           "rate_budget exhausted: #{calls_used} call(s) spent, #{pending} more needed, " <>
             "daily budget #{budget} — the feed pauses; the next sync resumes from the cursor",
         calls_used: calls_used
       )}
    else
      :ok
    end
  end

  defp maybe_limit(records, nil), do: records
  defp maybe_limit(records, limit), do: Enum.take(records, limit)

  # The cursor resumes STRICTLY AFTER the last record's SystemModstamp —
  # an equal-timestamp boundary must not re-land forever. Records carry
  # ISO strings from the API; the comparison is on the parsed instant
  # when both sides parse, falling back to the string ordering.
  defp next_cursor([], cursor), do: cursor || %{}

  defp next_cursor(records, _cursor) do
    max_value =
      records
      |> Enum.map(&Map.get(&1, @cursor_field))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(&cursor_compare/2)

    %{@cursor_field => max_value}
  end

  defp complete?(records, limit) when is_integer(limit), do: length(records) < limit
  defp complete?(_records, _limit), do: true

  defp cursor_compare(a, b) do
    case {parse_dt(a), parse_dt(b)} do
      {{:ok, da}, {:ok, db}} -> DateTime.compare(da, db) == :gt
      _ -> to_string(a) > to_string(b)
    end
  end

  defp parse_dt(value) when is_binary(value) do
    case DateTime.from_iso8601(String.replace_suffix(value, "+0000", "Z")) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_dt(%DateTime{} = dt), do: {:ok, dt}
  defp parse_dt(_), do: :error
end
