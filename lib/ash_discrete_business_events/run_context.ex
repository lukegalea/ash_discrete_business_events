# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.RunContext do
  @moduledoc """
  Fan-out parent propagation (design §3.4) — the package-owned conventions
  every adapter inherits instead of re-deriving.

  The process dictionary does not cross process boundaries, so a run's
  parent identity travels as DATA:

    * **Into Oban args as STRING keys** (`put_parent/2`): Oban serializes
      args through JSON, and an atom key misses silently after the round
      trip. This module writes and reads only the string key — an atom-keyed
      look-alike is invisible to it, on purpose (the iron law).
    * **Re-established at worker entry** (`enter_from_args/2` →
      `establish/2`): the parent id goes back into the worker's scope — the
      process dictionary here, plus the host's correlation scope when one is
      configured:

          config :ash_discrete_business_events, :scope_establisher,
            {AshEnterprise.Platform.Correlation, :with_correlation}

      The establisher is a `{module, function}` of arity 2 — it receives
      `(parent_id, fun)` and runs `fun` in that scope (`Correlation.with_
      correlation/2`'s exact shape). Absent, only this module's dictionary
      scope is established.
    * **Passed explicitly across Task fan-outs** (`fan_out/3`): spawned tasks
      capture the current parent BEFORE spawning and re-establish it inside
      each task — spawn does not inherit the scope, so the passing is this
      module's job, never the scheduler's.

  Emission ties in through `AshDiscreteBusinessEvents.Lineage.parent_opts/0`:
  a nested run (depth > 0 per the correlation provider) whose parent id
  resolves adds the `parent` run facet; the facet is omitted rather than
  fabricated when no id resolves.
  """

  # The parent id travels in Oban args under this STRING key — atom keys
  # miss silently after JSON round-trips (the iron law), so this module
  # reads only this binary key and nothing else.
  @parent_key "bizev_parent_run_id"
  @scope_key :bizev_parent_run_id

  @doc "The args key carrying the parent run id — a string key, always."
  @spec parent_key() :: String.t()
  def parent_key, do: @parent_key

  @doc """
  Puts the parent run id into Oban args under the string key. Returns the
  args map (atom-keyed input maps are fine — Oban's JSON serialization is
  what makes the string key load-bearing on the READ side).
  """
  @spec put_parent(map(), String.t() | nil) :: map()
  def put_parent(args, parent_id) when is_map(args) do
    if parent_id in [nil, ""] do
      args
    else
      Map.put(args, @parent_key, parent_id)
    end
  end

  @doc """
  Reads the parent run id back from args — the string key ONLY. An
  atom-keyed look-alike (`%{bizev_parent_run_id: id}`) reads as nil: after
  a JSON round-trip it would not exist anyway, and pretending otherwise is
  how the miss goes silent.
  """
  @spec parent_from_args(map()) :: String.t() | nil
  def parent_from_args(args) when is_map(args) do
    case Map.fetch(args, @parent_key) do
      {:ok, id} when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc """
  Worker entry: reads the parent from (possibly JSON-round-tripped) Oban
  args and runs `fun` with that scope re-established.
  """
  @spec enter_from_args(map(), (-> result)) :: result when result: var
  def enter_from_args(args, fun) when is_map(args) and is_function(fun, 0) do
    args |> parent_from_args() |> establish(fun)
  end

  @doc """
  Establishes the parent scope for the current process and runs `fun`:
  the id lands in this module's dictionary (`current_parent/0`), and the
  configured host scope establisher — `{module, function}` of arity 2 —
  wraps `fun` in the host's correlation scope. The previous scope is
  restored afterwards.
  """
  @spec establish(String.t() | nil, (-> result)) :: result when result: var
  def establish(parent_id, fun) when is_function(fun, 0) do
    previous = Process.put(@scope_key, parent_id)

    try do
      case scope_establisher() do
        nil -> fun.()
        {module, function} -> apply(module, function, [parent_id, fun])
      end
    after
      restore_scope(previous)
    end
  end

  @doc "The current process's parent run id, or nil."
  @spec current_parent() :: String.t() | nil
  def current_parent, do: Process.get(@scope_key)

  @doc """
  Explicit parent passing across a `Task.async_stream/3` fan-out: the
  current parent is captured BEFORE spawning and re-established inside each
  spawned task — spawn does not inherit the scope, so this module passes it,
  explicitly. Consumed like `Task.async_stream/3`'s result; defaults to
  `timeout: :infinity` (a data batch is not a five-second problem).
  """
  @spec fan_out(Enumerable.t(elem), (elem -> term), keyword()) :: Enumerable.t()
        when elem: var
  def fan_out(items, fun, opts \\ []) when is_function(fun, 1) do
    parent = current_parent()

    opts =
      [timeout: :infinity]
      |> Keyword.merge(opts)

    Task.async_stream(
      items,
      fn item -> establish(parent, fn -> fun.(item) end) end,
      opts
    )
  end

  defp scope_establisher do
    Application.get_env(:ash_discrete_business_events, :scope_establisher)
  end

  defp restore_scope(previous), do: Process.put(@scope_key, previous)
end
