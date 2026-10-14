# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Dsl.Mapping.Ops do
  @moduledoc """
  The closed operator vocabulary (§5.3, the ash_strangler shape) — one
  entity schema per operator, so each shape accepts only its own
  options and a typo is a compile error.

  Redundancy is refused BY NAME by the compiler
  (`AshDiscreteBusinessEvents.Verifiers.VerifyMappings`): two operators
  writing the same target key fail compilation, each named with its
  position. Known-dangerous combos are refused too: `constant` with a
  nil value (that is `unmapped_because`'s job), empty `coalesce`/`concat`
  paths, empty `decode` cases, and — the occurred-vs-observed discipline
  (§1.3) — anything but a datetime-typed extraction for `occurred_at`,
  which every mapping must have.
  """

  alias AshDiscreteBusinessEvents.Dsl.Mapping.Op

  @type_suffix "Casts the written value with this Ash type."

  @doc false
  def map do
    %Spark.Dsl.Entity{
      name: :map,
      describe: """
      Maps a source payload path to a target key, casting to `type`.
      """,
      examples: [
        ~s(map :stage, from: "StageName", type: :string)
      ],
      target: Op,
      args: [:target],
      auto_set_fields: [op: :map],
      schema: [
        target: [type: :atom, required: true, doc: "The canonical target key."],
        from: [
          type: :string,
          required: true,
          doc: "The source payload path (dot-separated for nested maps)."
        ],
        type: [type: :atom, default: :string, doc: @type_suffix]
      ]
    }
  end

  @doc false
  def decode do
    %Spark.Dsl.Entity{
      name: :decode,
      describe: """
      Translates a source value through `cases` (source value → canonical
      value). A present source value with no case is a loud apply-time
      error — routing surprises must not fold silently; `default` covers
      the genuinely-unmapped.
      """,
      examples: [
        ~s(decode :stage_bucket, from: "StageName", cases: %{"Prospecting" => "early"})
      ],
      target: Op,
      args: [:target],
      auto_set_fields: [op: :decode, type: :string],
      schema: [
        target: [type: :atom, required: true, doc: "The canonical target key."],
        from: [
          type: :string,
          required: true,
          doc: "The source payload path (dot-separated for nested maps)."
        ],
        cases: [
          # {:map, :any, :any} — case keys are JSON terms (strings,
          # numbers, booleans), not atoms; the plain :map type would
          # demand atom keys.
          type: {:map, :any, :any},
          required: true,
          doc: "Source value → canonical value. Keys and values must be JSON terms."
        ],
        default: [
          type: :any,
          doc: "Written when the source path is absent. A PRESENT value with no case errors."
        ],
        type: [type: :atom, doc: @type_suffix]
      ]
    }
  end

  @doc false
  def coalesce do
    %Spark.Dsl.Entity{
      name: :coalesce,
      describe: "Writes the first non-nil value among the given payload paths.",
      examples: [
        ~s(coalesce :close_date, from: ["CloseDate", "ExpectedCloseDate"])
      ],
      target: Op,
      args: [:target],
      auto_set_fields: [op: :coalesce],
      schema: [
        target: [type: :atom, required: true, doc: "The canonical target key."],
        from: [
          type: {:list, :string},
          required: true,
          doc: "Payload paths, in priority order."
        ]
      ]
    }
  end

  @doc false
  def concat do
    %Spark.Dsl.Entity{
      name: :concat,
      describe: "Joins the non-nil stringified values of the given payload paths.",
      examples: [
        ~s(concat :label, from: ["Name", "StageName"], separator: " / ")
      ],
      target: Op,
      args: [:target],
      auto_set_fields: [op: :concat, separator: " "],
      schema: [
        target: [type: :atom, required: true, doc: "The canonical target key."],
        from: [
          type: {:list, :string},
          required: true,
          doc: "Payload paths to join, in order."
        ],
        separator: [type: :string, default: " ", doc: "The joiner."]
      ]
    }
  end

  @doc false
  def constant do
    %Spark.Dsl.Entity{
      name: :constant,
      describe: "Writes a fixed JSON-term value. A nil value is refused — that is `unmapped_because`'s job.",
      examples: [
        ~s(constant :source_system, value: "salesforce")
      ],
      target: Op,
      args: [:target],
      auto_set_fields: [op: :constant, type: :string],
      schema: [
        target: [type: :atom, required: true, doc: "The canonical target key."],
        value: [
          type: {:or, [:string, :integer, :float, :boolean]},
          required: true,
          doc: "The fixed value (a JSON term — the artifact must hash deterministically)."
        ],
        type: [type: :atom, doc: @type_suffix]
      ]
    }
  end

  @doc false
  def unmapped_because do
    %Spark.Dsl.Entity{
      name: :unmapped_because,
      describe: """
      Declares that a target key is deliberately NOT mapped, and why.
      Refusal-by-name: the gap is authored data, carried on the artifact,
      surfaced by `run/3` — never a silent absence.
      """,
      examples: [
        ~s(unmapped_because :owner_email, "PII — kept out of canonical events, §9.5")
      ],
      target: Op,
      args: [:target, :reason],
      auto_set_fields: [op: :unmapped_because],
      schema: [
        target: [type: :atom, required: true, doc: "The deliberately-unmapped canonical key."],
        reason: [type: :string, required: true, doc: "Why it is unmapped — carried on the artifact."]
      ]
    }
  end
end
