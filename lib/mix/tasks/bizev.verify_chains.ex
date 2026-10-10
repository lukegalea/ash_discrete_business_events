# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.Bizev.VerifyChains do
  @moduledoc """
  Verifies the per-region hash chains of a ledger emitted by the
  `:ledger` macro (and, via the same run, its simulation twin).

      mix bizev.verify_chains --resource MyApp.Ledger
      mix bizev.verify_chains --resource MyApp.Ledger --region us
      mix bizev.verify_chains --resource MyApp.Ledger --json

  Exits non-zero if any region's chain reports findings. `--resource` is
  required; the repo and table come from the resource's own `postgres`
  declaration. The twin's table is verified by the same run (`verify_all`
  walks both), because a chain that is clean on the real ledger while the
  simulation ledger drifts is exactly the kind of quiet divergence the
  twin exists to prevent.
  """

  use Mix.Task

  alias AshDiscreteBusinessEvents.Ledger.VerifyChains

  @shortdoc "Verify the ledger's per-region hash chains"
  @impl Mix.Task
  def run(args) do
    {opts, _argv} =
      OptionParser.parse!(args, strict: [resource: :string, region: :string, json: :boolean])

    resource =
      case opts[:resource] do
        nil ->
          raise OptionParser.ParseError,
                "missing required option --resource (the ledger module to verify)"

        mod_string ->
          String.to_existing_atom(mod_string)
      end

    Mix.Task.run("app.start", [])

    results =
      case opts[:region] do
        nil -> VerifyChains.verify_all(resource)
        region -> [VerifyChains.verify(resource, String.to_existing_atom(region))]
      end

    if opts[:json] do
      Mix.shell().info(Jason.encode!(results, pretty: true))
    else
      Enum.each(results, &report_region/1)
    end

    if VerifyChains.clean?(results) do
      :ok
    else
      Mix.raise("chain verification found integrity findings")
    end
  end

  defp report_region(result) do
    status = if result.findings == [], do: "OK", else: "BROKEN"

    Mix.shell().info(
      "#{status}  region #{inspect(result.region)}: #{result.checked} checked" <>
        skip_note(result.skipped_unchained_prefix)
    )

    Enum.each(result.findings, &report_finding/1)
  end

  defp report_finding(finding) do
    Mix.shell().info(
      "      #{finding.problem} at sequence #{finding.sequence} " <>
        "(#{inspect(finding.event_kind)})"
    )
  end

  defp skip_note(0), do: ""
  defp skip_note(n), do: " (#{n} unchained prefix rows skipped)"
end
