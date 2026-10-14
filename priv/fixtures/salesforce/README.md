# The Salesforce fixture corpus

The honest early demo input (design §8): a synthesized but realistic
dev-org-shaped **Opportunity export** — nine monthly Bulk API 2.0
snapshots (state snapshots cursorable by `SystemModstamp`, not an event
feed), delivered as the exact CSVs a Bulk 2.0 results download returns.

- `run-2026-01.csv` … `run-2026-09.csv` — one snapshot per month; the
  raw layer's periods across runs ARE the version transitions (§7).
- `manifest.json` — per-run `fetched_at` (the observation instants),
  row counts, cursor field, license.
- `generate_corpus.exs` — the deterministic, hash-derived generator;
  re-running reproduces the CSVs byte-for-byte. The committed CSVs are
  the authoritative corpus.

**CC0-1.0** (see `LICENSE`): this corpus is data, free of rights — the
AST-153 corpus pattern. It contains no real person, org, or token data.

Shapes it deliberately exercises: 68 opportunities growing over 9
months, 133 version transitions, amount amendments (corrections), and
one **late arrival** — subject `0065f000000000003`'s March row carries a
`SystemModstamp` earlier than February's maximum (invisible to
cursoring, present in the captured download, backdated at the ledger).

Import it through the full land → map → ledger path with
`AshDiscreteBusinessEvents.Adapters.SalesforceBulk20.FixtureCorpus.import/1`.

## Corrections variant (`corrections/`)

`revision-2026-06.csv` — the retroactive revision the corrections demo
replays: subject `0065f000000000004`'s June row, restated (Closed Won →
Negotiation) at the SAME SystemModstamp. When armed
(`FixtureCorpus.arm_revision!/2`), the corpus transport merges it over
the served June snapshot — the source rewrote history — and the
land→map→ledger path derives a superseding event
(`supersedes_event_id` → the original June event, never rewritten).
CC0-1.0, same as the corpus.
