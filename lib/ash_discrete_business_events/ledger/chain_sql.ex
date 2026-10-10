# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Ledger.ChainSQL do
  @moduledoc """
  The per-region hash chain's SQL, in ONE place.

  The chain is written by a `BEFORE INSERT` trigger (the audit log's
  pattern: SHA-256 over the row's contents concatenated with the previous
  per-region hash) and verified by walking the chain and recomputing the
  digest **in SQL using the same expression the trigger uses** — two
  implementations of one canonical form is how a verifier ends up
  disagreeing with reality about `NULL`s, JSON key order and timestamp
  formatting (the ash_enterprise audit lesson, carried verbatim). Both
  sides build their SQL from the fragments here, so the canonical form
  has exactly one definition per clause.

  The chain is per region (§6): a global chain would serialize every
  write in the system, and a per-region partition that a cross-region
  total could silently merge is the honesty the design demands. The
  trigger piggybacks on the advisory lock the record change takes — no
  new serialization.
  """

  @chain_columns ~w(
    record_id version occurred_at observed_at resource action action_type
    subject_type subject_external_id subject_stream
    actor_type actor_external_id actor_display
    data context provenance supersedes_event_id delivery_key
    region residency_tag
  )a

  @doc "The columns that participate in the chain digest, in canonical order."
  @spec columns() :: [atom()]
  def columns, do: @chain_columns

  @doc """
  The `concat_ws('|', ...)` digest input over the chain columns. Every
  value is coalesced to `''` so `NULL`s and empty strings digest alike;
  `::text` casts match the trigger's casts. `prefix` is the row prefix —
  `NEW.` inside the trigger, `""` in the verifier (where `previous_hash`
  comes from `lag(hash) OVER (ORDER BY sequence)`, the actual chain
  neighbour, so an altered row shows as `:altered` and a removed or
  out-of-band row shows as `:broken_link`).
  """
  @spec digest_expression(String.t()) :: String.t()
  def digest_expression(prefix) do
    values =
      Enum.map(@chain_columns, fn column ->
        "coalesce(#{prefix}#{column}::text, '')"
      end)

    "concat_ws('|',\n       " <>
      Enum.join(["coalesce(#{prefix}previous_hash, '')" | values], ",\n       ") <> ")"
  end

  @doc """
  The `BEFORE INSERT` chain function for `table`.

  Reads the previous hash from the region's chain tail (the record
  change's advisory lock guarantees no concurrent tail), sets
  `previous_hash` and `hash`.
  """
  @spec chain_function_sql(String.t(), String.t()) :: String.t()
  def chain_function_sql(table, function_name) do
    """
    CREATE OR REPLACE FUNCTION #{function_name}() RETURNS trigger AS $fn$
    DECLARE
      prev text;
    BEGIN
      SELECT hash INTO prev
      FROM #{table}
      WHERE region = NEW.region
      ORDER BY sequence DESC
      LIMIT 1;

      NEW.previous_hash := prev;
      NEW.hash := encode(sha256(convert_to(#{digest_expression("NEW.")}, 'UTF8')), 'hex');

      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  @doc "The chain trigger: fires `function` before each insert on `table`."
  @spec chain_trigger_sql(String.t(), String.t(), String.t()) :: String.t()
  def chain_trigger_sql(table, function_name, trigger_name) do
    """
    CREATE TRIGGER #{trigger_name}
      BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function_name}();
    """
  end

  @doc """
  The immutability function: UPDATE/DELETE raise. Row-level on purpose —
  TRUNCATE stays allowed, because a reset has to work and a TRUNCATE is
  not a quiet edit: it takes the whole table, which is conspicuous in a
  way one altered row is not.
  """
  @spec immutability_function_sql(String.t()) :: String.t()
  def immutability_function_sql(table) do
    """
    CREATE OR REPLACE FUNCTION bizev_#{table}_immutable_fn() RETURNS trigger AS $fn$
    BEGIN
      RAISE EXCEPTION '#{table} is append-only; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Correct a wrong entry by recording a new one.';
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  @doc "The immutability trigger, bound to `immutability_function_sql/1`."
  @spec immutability_trigger_sql(String.t()) :: String.t()
  def immutability_trigger_sql(table) do
    """
    CREATE TRIGGER bizev_#{table}_immutable
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION bizev_#{table}_immutable_fn();
    """
  end
end
