# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.Corrections do
  @moduledoc """
  Corrections-as-events (design §7): the derivation of
  `supersedes_event_id`, and the replay-safe truth-point register it
  stands on.

  When a mapping sees a SourceRecord version whose extracted facts
  differ from a previously-ledgered event **for the same subject
  truth-point** (same `occurred_at`), it derives a NEW ledger event
  carrying `supersedes_event_id` pointing at the current truth — the
  original is never rewritten (chain integrity), and the correction is
  an ordinary, chained, projector-visible event.

  Three outcomes for one canonical fact against the register:

    * `:new` — the truth-point is unseen: a plain new event.
    * `:duplicate` — the point holds the SAME data: a replay folds away
      (identical content is never re-recorded — the BIZEV-7 rule).
    * `{:correction, original_event_id}` — the point holds DIFFERENT
      data: a correction superseding the current truth at that instant.

  The register is seeded from the ledger's own history (every ledgered
  event per subject and truth instant, latest sequence winning), so a
  replay folds against what the ledger ALREADY holds, and a correction
  supersedes the CURRENT truth at that point (a second correction
  supersedes the first — each correction is the new present).

  Raw SQL on purpose: the register needs only
  `(record_id, occurred_at, data, id)` — reading ledger rows through
  the resource would drag the machinery columns (the replay-routing
  atom) through Ash's atom loading for no benefit.
  """

  defstruct points: %{}

  @typedoc """
  `subject => (point => %{data:, event_id:})` — the current truth per
  subject per instant. Points are epoch-second strings (deterministic
  across the SQL and the Elixir sides).
  """
  @type t :: %__MODULE__{
          points: %{String.t() => %{String.t() => %{data: map(), event_id: String.t()}}}
        }

  @doc """
  Seeds the register from `ledger`'s history in `region`: every event's
  `(subject, truth-point) → {data, id}`, latest sequence winning.
  """
  @spec seed(ledger :: module(), region :: atom()) :: t()
  def seed(ledger, region) do
    repo = AshPostgres.DataLayer.Info.repo(ledger)
    table = AshPostgres.DataLayer.Info.table(ledger)

    %{rows: rows} =
      repo.query!(
        "SELECT record_id, extract(epoch from occurred_at)::bigint, data, id " <>
          "FROM #{table} WHERE region = $1 ORDER BY sequence",
        [to_string(region)]
      )

    points =
      Enum.reduce(rows, %{}, fn [record_id, epoch, data, id], acc ->
        point = Integer.to_string(epoch)

        acc
        |> Map.put_new(record_id, %{})
        |> put_in([record_id, point], %{data: data, event_id: id})
      end)

    %__MODULE__{points: points}
  end

  @doc """
  Classifies one canonical fact against the register (see the module
  doc for the three outcomes). Pure — the register is updated separately
  by `put/5` after a successful append.
  """
  @spec classify(t(), String.t(), DateTime.t(), map()) ::
          :new | :duplicate | {:correction, %{event_id: String.t()}}
  def classify(register, subject, occurred_at, data) do
    point = point_key(occurred_at)
    known = register.points[subject][point]

    cond do
      is_nil(known) -> :new
      known.data == data -> :duplicate
      true -> {:correction, %{event_id: known.event_id}}
    end
  end

  @doc """
  Records the outcome in the register after a successful append: this
  point's current truth is now `{data, event_id}`.
  """
  @spec put(t(), String.t(), DateTime.t(), map(), String.t()) :: t()
  def put(register, subject, occurred_at, data, event_id) do
    point = point_key(occurred_at)
    subject_points = Map.get(register.points, subject, %{})

    %{
      register
      | points:
          Map.put(
            register.points,
            subject,
            Map.put(subject_points, point, %{
              data: data,
              event_id: event_id
            })
          )
    }
  end

  @doc "The truth-point key for an instant — epoch seconds, as strings."
  @spec point_key(DateTime.t()) :: String.t()
  def point_key(occurred_at), do: Integer.to_string(DateTime.to_unix(occurred_at))

  @doc "The register's subject count (tests and demos)."
  @spec subjects(t()) :: non_neg_integer()
  def subjects(register), do: map_size(register.points)
end
