# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.ReqTransport do
  @moduledoc """
  The live Bulk 2.0 wiring over `Req`: create job → poll → download.

  **Not yet exercised against a live org** — CI runs the adapter against
  the fixture-corpus transport (§8: production Salesforce connects only
  after the fixture path is boring). This module exists so the seam is
  real: the endpoints, the versioned path, the CSV results parsing. The
  known simplification: results CSV parsing here handles plain,
  unquoted-comma CSV (Salesforce quotes only when a field contains the
  delimiter; the corpus generator keeps names comma-free). When a live
  org needs full RFC 4180, that lands here.

  Each callback is one API call — the adapter accounts them against the
  source's `rate_budget`.
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.Transport

  @api_version "v62.0"
  @default_timeout 30_000

  @impl true
  def create_query_job(%{instance_url: url, token: token}, soql, opts) do
    case req(:post, "#{url}/services/data/#{@api_version}/jobs/query", token,
           json: %{operation: "query", query: soql},
           opts: opts
         ) do
      {:ok, %{status: 200, body: %{"id" => id}}} -> {:ok, id}
      {:ok, %{status: status, body: body}} -> {:error, {:job_create_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def job_state(%{instance_url: url, token: token}, job_id, opts) do
    case req(:get, "#{url}/services/data/#{@api_version}/jobs/query/#{job_id}", token, opts: opts) do
      {:ok, %{status: 200, body: %{"state" => state}}} -> decode_state(state)
      {:ok, %{status: status, body: body}} -> {:error, {:job_state_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download_results(%{instance_url: url, token: token}, job_id, opts) do
    with {:ok, %{status: 200, body: body}} <-
           req(:get, "#{url}/services/data/#{@api_version}/jobs/query/#{job_id}/results", token,
             opts: opts
           ),
         result_urls = result_urls(body, url, opts),
         {:ok, rows} <- fetch_all(result_urls, token, opts) do
      {:ok, %{records: rows, pk_chunked?: pk_chunked?(body)}}
    end
  end

  # Single-chunk jobs return a bare SObject array; PK-chunked jobs return
  # a list of locator URLs.
  defp result_urls(body, url, opts) when is_list(body) and body != [] do
    Enum.map(body, fn %{"url" => suffix} ->
      "#{url}#{suffix}#{locator_opts(suffix, opts)}"
    end)
  end

  defp result_urls(_body, url, opts) do
    ["#{url}/services/data/#{@api_version}/jobs/query/results#{locator_opts("", opts)}"]
  end

  defp pk_chunked?(body) when is_list(body), do: true
  defp pk_chunked?(_), do: false

  defp fetch_all(urls, token, opts) do
    rows =
      Enum.flat_map(urls, fn url ->
        case req(:get, url, token, opts: opts) do
          {:ok, %{status: 200, body: csv}} -> parse_csv(csv)
          {:ok, %{status: status, body: body}} -> throw({:error, {:download_failed, status, body}})
          {:error, reason} -> throw({:error, reason})
        end
      end)

    {:ok, rows}
  catch
    {:error, _} = error -> error
  end

  defp locator_opts(_suffix, opts) do
    case Keyword.get(opts, :max_records) do
      nil -> ""
      n -> "?maxRecords=#{n}"
    end
  end

  defp decode_state("UploadComplete"), do: {:ok, :completed}
  defp decode_state("JobComplete"), do: {:ok, :completed}
  defp decode_state("Open"), do: {:ok, :in_progress}
  defp decode_state("Processing"), do: {:ok, :in_progress}
  defp decode_state("Aborted"), do: {:error, :job_failed}
  defp decode_state("Failed"), do: {:error, :job_failed}

  defp req(method, url, token, opts) do
    request_opts =
      Keyword.get(opts, :req_opts, [])
      |> Keyword.put_new(:receive_timeout, @default_timeout)
      |> Keyword.put(:retry, false)

    Req.request(method,
      url: url,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ],
      opts: request_opts
    )
  end

  # Minimal CSV: header row + one line per record, comma-delimited,
  # double-quote escaping only (a quoted field never contains a newline
  # in Bulk 2.0 result sets for the fields this package targets).
  defp parse_csv(csv) when is_binary(csv) do
    lines =
      csv
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        {:ok, []}

      [header | data_lines] ->
        keys = split_line(header)

        {:ok,
         Enum.map(data_lines, fn line ->
           line |> split_line() |> Enum.zip(keys) |> Map.new()
         end)}
    end
  end

  defp parse_csv(other), do: {:error, {:unexpected_results_body, other}}

  defp split_line(line) do
    line
    |> String.split(",", trim: false)
    |> Enum.map(fn field ->
      field
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> String.replace("\"\"", "\"")
    end)
  end
end
