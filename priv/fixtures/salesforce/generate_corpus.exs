# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ast-forks/ash_discrete_business_events>
#
# SPDX-License-Identifier: CC0-1.0

# The fixture corpus generator — a deterministic, dev-org-shaped synthesis
# of nine monthly Bulk API 2.0 snapshots (state snapshots cursorable by
# SystemModstamp, §7), each a CSV exactly as a Bulk 2.0 results download
# looks.
#
# Run from the repo root:
#
#     MIX_ENV=test mix run priv/fixtures/salesforce/generate_corpus.exs
#
# Everything is hash-derived (no clocks, no entropy): re-running on the
# same OTP reproduces the committed CSVs byte-for-byte. The COMMITTED
# CSVs are the authoritative corpus — the generator documents their
# provenance. CC0-1.0: the corpus is data, free of rights.

defmodule CorpusGenerator do
  @output_dir Path.dirname(__ENV__.file)
  @months ~w(2026-01 2026-02 2026-03 2026-04 2026-05 2026-06 2026-07 2026-08 2026-09)
  @month_index Enum.with_index(@months, 1) |> Map.new()
  @created_per_month %{
    "2026-01" => 24,
    "2026-02" => 6,
    "2026-03" => 6,
    "2026-04" => 6,
    "2026-05" => 6,
    "2026-06" => 5,
    "2026-07" => 5,
    "2026-08" => 5,
    "2026-09" => 5
  }
  @open_stages ~w(Prospecting Qualification Proposal Negotiation)
  @header ["Id", "Name", "StageName", "Amount", "CloseDate", "SystemModstamp"]
  # The subject whose March stamp deliberately precedes February's max —
  # the late-arrival path (§7: a truth time learned late).
  @backdated_subject "0065f000000000003"

  def run do
    state = Enum.reduce(@months, %{opps: %{}}, &run_month/2)

    total_opps = map_size(state.opps)

    transitions =
      state.opps
      |> Enum.map(fn {_id, opp} -> max(length(opp.history) - 1, 0) end)
      |> Enum.sum()

    rows_total =
      Enum.reduce(@months, 0, fn month, acc -> acc + length(snapshot(month, state)) end)

    manifest = %{
      source: %{
        object: "Opportunity",
        cursor_field: "SystemModstamp",
        note:
          "Monthly snapshots: one query job per run, WHERE SystemModstamp > <cursor> " <>
            "ORDER BY SystemModstamp — the raw layer's periods are the version transitions"
      },
      license: "CC0-1.0",
      generated_by: "priv/fixtures/salesforce/generate_corpus.exs (hash-derived, no entropy)",
      runs:
        Enum.map(@months, fn month ->
          %{
            file: "run-#{month}.csv",
            fetched_at: fetched_at(month),
            rows: length(snapshot(month, state))
          }
        end)
    }

    File.write!(Path.join(@output_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

    IO.puts("""
    corpus written to #{@output_dir}
      runs: #{length(@months)}
      opportunities: #{total_opps}
      version transitions: #{transitions}
      total rows: #{rows_total}
    """)
  end

  # The run's observation instant — deterministic per month, stamped on
  # landed SourceRecords as fetched_at (the period basis).
  def fetched_at(month) do
    "#{month}-05T02:00:00Z"
  end

  # ── one month ─────────────────────────────────────────────────────────

  defp run_month(month, state) do
    state = create_new(month, state)
    state = advance_and_amend(month, state)
    write(month, snapshot(month, state))
    state
  end

  defp create_new(month, state) do
    n = Map.fetch!(@created_per_month, month)

    prior =
      @created_per_month
      |> Map.delete(month)
      |> Map.filter(fn {m, _} -> Map.fetch!(@month_index, m) < Map.fetch!(@month_index, month) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    Enum.reduce(1..n//1, state, fn i, state ->
      idx = prior + i
      id = subject_id(idx)
      entry = %{month: month, stage: Enum.at(@open_stages, rem(idx, 4)), amount: 15_000 + rem(hash({id, :initial}), 48) * 2_500}

      case state.opps do
        %{^id => _} ->
          state

        _ ->
          opp = %{name: name(idx), close_date: close_date(month, idx), history: [entry]}
          put_in(state.opps[id], opp)
      end
    end)
  end

  # Each month: some open opps advance a stage, a few amounts amend in
  # place (§7's corrections are events).
  defp advance_and_amend(month, state) do
    update_in(state.opps, fn opps ->
      opps
      |> Enum.sort()
      |> Enum.map(fn {id, opp} -> {id, advance_opp(id, opp, month)} end)
      |> Map.new()
    end)
  end

  defp advance_opp(id, opp, month) do
    current = List.last(opp.history)

    cond do
      Map.fetch!(@month_index, current.month) >= Map.fetch!(@month_index, month) ->
        opp

      # The late arrival: a March transition whose SystemModstamp is
      # backdated into January (stamp/1 shifts it) — different content,
      # old truth time, learned in the March run (§7).
      id == @backdated_subject and month == "2026-03" and current.stage in @open_stages ->
        entry = %{month: month, stage: "Closed Won", amount: current.amount}
        %{opp | history: opp.history ++ [entry]}

      current.stage not in @open_stages ->
        opp

      advance?(id, month, current.stage) ->
        entry = %{month: month, stage: next_stage(id, month, current.stage), amount: current.amount}
        %{opp | history: opp.history ++ [entry]}

      amend?(id, month) ->
        entry = %{month: month, stage: current.stage, amount: current.amount + 2_500}
        %{opp | history: opp.history ++ [entry]}

      true ->
        opp
    end
  end

  defp advance?(id, month, stage), do: rem(hash({id, month, :adv, stage}), 10) < 5
  defp amend?(id, month), do: rem(hash({id, month, :amend}), 10) == 7

  defp next_stage(_id, _month, "Prospecting"), do: "Qualification"
  defp next_stage(_id, _month, "Qualification"), do: "Proposal"
  defp next_stage(_id, _month, "Proposal"), do: "Negotiation"

  defp next_stage(id, month, "Negotiation") do
    if rem(hash({id, month, :close}), 5) == 0, do: "Closed Lost", else: "Closed Won"
  end

  # ── the snapshot: state as of this month, one row per live opp ────────

  defp snapshot(month, state) do
    idx = Map.fetch!(@month_index, month)

    state.opps
    |> Enum.filter(fn {_id, opp} ->
      Enum.any?(opp.history, fn entry -> Map.fetch!(@month_index, entry.month) <= idx end)
    end)
    |> Enum.sort()
    |> Enum.map(fn {id, opp} -> row(id, opp, month, idx) end)
  end

  defp row(id, opp, month, idx) do
    current =
      opp.history
      |> Enum.reverse()
      |> Enum.find(fn entry -> Map.fetch!(@month_index, entry.month) <= idx end)

    %{
      "Id" => id,
      "Name" => opp.name,
      "StageName" => current.stage,
      "Amount" => current.amount,
      "CloseDate" => opp.close_date,
      "SystemModstamp" => stamp(id, current)
    }
  end

  # ── deterministic field derivations ───────────────────────────────────

  defp subject_id(i), do: "0065f00000000" <> String.pad_leading(Integer.to_string(i), 4, "0")

  defp hash(term), do: :erlang.phash2(term, 4_294_967_296)

  defp name(idx) do
    words =
      ~w(Northwind Summit Ridge Harbor Delta Vector Atlas Meridian Cobalt Lumen Pilcrow
         Basalt Cirrus Quarry Amber Juniper Keystone Foundry Marigold Solstice Trellis
         Vantage Whitfield Zephyr Ardent Bramble Cinder Elmwood Fernwood Goldleaf Highpark)

    "#{Enum.at(words, rem(idx, length(words)))} #{String.pad_leading(Integer.to_string(idx), 3, "0")} renewal"
  end

  defp close_date(month, idx) do
    m = Map.fetch!(@month_index, month)
    close_m = Integer.mod(m + rem(idx, 3), 12) + 1
    day = 10 + rem(idx, 15)

    "2026-" <>
      String.pad_leading(Integer.to_string(close_m), 2, "0") <>
      "-" <> String.pad_leading(Integer.to_string(day), 2, "0")
  end

  # SystemModstamp in Salesforce's own shape (ISO8601 +0000), bounded to
  # the entry's month so cursoring (>) advances run over run. The one
  # backdated subject stamps 30 days earlier than its month — a truth
  # time learned late.
  defp stamp(id, entry) do
    m = Map.fetch!(@month_index, entry.month)
    h = hash({id, entry.stage, entry.month})

    dt = %DateTime{
      year: 2026,
      month: m,
      day: rem(h, 26) + 1,
      hour: rem(div(h, 100), 21) + 2,
      minute: rem(div(h, 10_000), 60),
      second: rem(div(h, 1_000_000), 60),
      microsecond: {0, 0},
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }

    dt =
      if id == @backdated_subject and m == 3 do
        DateTime.add(dt, -30 * 24 * 3600, :second)
      else
        dt
      end

    dt |> DateTime.to_iso8601() |> String.replace("Z", "+0000")
  end

  defp write(month, rows) do
    csv =
      ([Enum.join(@header, ",")] ++
         Enum.map(rows, fn row ->
           Enum.map_join(@header, ",", fn key ->
             value = row |> Map.fetch!(key) |> to_string()
             if String.contains?(value, ","), do: "\"#{value}\"", else: value
           end)
         end))
      |> Enum.join("\r\n")

    File.write!(Path.join(@output_dir, "run-#{month}.csv"), csv <> "\r\n")
  end
end

CorpusGenerator.run()
