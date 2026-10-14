# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.Transport do
  @moduledoc """
  The Bulk 2.0 HTTP seam — the one place `Req` touches Salesforce.

  The adapter (job lifecycle, cursoring, budget) is package logic tested
  against doubles of THIS behaviour; the Req transport below it is the
  live wiring (not exercised against a live org in CI — the fixture
  corpus is the honest stand-in until then, §8).

  `conn` is what the configured auth provider resolved (ADR 0011: the
  auth edge yields tokens; BIZEV never opens it) — for Bulk 2.0:
  `%{instance_url: url, token: token}`.
  """

  @typedoc "A Bulk 2.0 query job's handle."
  @type job_id :: String.t()

  @doc "Creates a query job for `soql`. One API call."
  @callback create_query_job(conn :: term(), soql :: String.t(), opts :: keyword()) ::
              {:ok, job_id()} | {:error, term()}

  @doc """
  Polls the job's state. One API call. `:completed` means results are
  ready; `:job_failed` carries the Salesforce failure message.
  """
  @callback job_state(conn :: term(), job_id(), opts :: keyword()) ::
              {:ok, :in_progress | :completed} | {:error, :job_failed | term()}

  @doc """
  Downloads ALL result sets (PK-chunked jobs return several — each
  download is an API call). Rows are parsed maps keyed by the API field
  name, exactly as the source emitted them.
  """
  @callback download_results(conn :: term(), job_id(), opts :: keyword()) ::
              {:ok, %{records: [map()], pk_chunked?: boolean()}} | {:error, term()}
end
