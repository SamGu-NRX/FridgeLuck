# Label-Numbers Evaluation Corpus

A deterministic synthetic corpus of nutrition-label text with per-field truth
tables, built to measure what the production `NutritionLabelParser`
(`apps/ios/Capability/Core/Recognition/NutritionLabelParser.swift`) can and
cannot read, and to catch regressions in that behavior on hosted CI (macOS) or
locally (Swift on Linux).

The corpus is synthetic. Numbers are arithmetically consistent
(kJ↔kcal, salt↔sodium, per-100g↔per-portion, per-serving↔per-package) so any
value a parser returns can be checked against the label's own arithmetic.

## Layout

- `generate_corpus.py` — generator (`--seed 20261010`, writes `corpus/labels.jsonl`)
- `corpus/labels.jsonl` — the generated corpus (480 records, committed)
- `corpus/CORPUS_COUNTS.json` — generation summary
- `check_corpus.py` — integrity checker (schema, evidence, justifications, arithmetic)
- `tests/` — pytest suite for generator and checker (`python3 -m pytest tests -q`)
- `SwiftReplay/` — Swift package that replays the production parser over the corpus

## Corpus schema

Each JSONL line is one record:

```
record_id, group_id, variant, family, variant_kind,
source {kind, generator, reference},
lines: [String],          // the OCR lines a parser sees
corruption: {...}|null,   // op, detail, affected — only on corrupted variants
fields: { "<field>@<basis>": {
    value, unit, basis, observable, evidence_line, unobservability_reason } }
```

Families (60 groups each, one clean + one corrupted record per group):

| family | label style |
|---|---|
| `us_dual_column` | US Nutrition Facts, per-serving and per-package columns |
| `ca_bilingual` | Canadian bilingual EN/FR per-serving label |
| `eu_per100g` | EU nutrition declaration, per 100 g / per 100 ml |
| `eu_per_portion` | EU typical values per 100 g and per portion |

Fields: `energy_kcal`, `energy_kj`, `fat_g`, `carbohydrate_g`, `protein_g`,
`sodium_mg`, `salt_g`, `serving_size`, `servings_per_container`.

Every unobservable entry carries an independently checkable
`unobservability_reason`: `not_declared`, `value_not_in_text`,
`field_name_missing`, `unit_missing`, or `basis_header_missing`.

Corruption ops (one per corrupted record, applied to a copy of the clean label):
digit substitution (`0→O/Q`, `1→l/I`, …), field-name damage, unit damage,
decimal-point shredding, thousands-separator mangling, and digit surgery on the
serving-size header (which can remove a basis marker).

## Usage

```bash
# regenerate (deterministic for a fixed seed)
python3 generate_corpus.py --seed 20261010 --out corpus/labels.jsonl

# verify integrity
python3 check_corpus.py            # exits 0 on the committed corpus

# Python tests
python3 -m pytest tests -q

# Swift replay (production parser vs truth)
cd SwiftReplay && swift test
swift run label-numbers-replay     # prints the replay report as JSON
```

## Replay findings (production parser vs this corpus)

Measured by `SwiftReplay`, 480 records:

- Calories extract perfectly on clean US and Canadian labels (60/60 each); the
  keyword gate also fires for both.
- Serving size never matches exactly (0/60 US clean): the parser's capture
  pattern is greedy on the joined text and overruns into the text that follows
  (`"Serving size 3 cookies (30 g) Amount per serving …"`).
- Servings-per-container never matches (0/60 US clean): the production pattern
  expects the count after the phrase, while these labels read
  `"About 11 servings per container"`.
- EU labels never trip the keyword gate (`Calories` / `serving size` /
  `servings per container` are absent) — `eu_per100g`/`eu_per_portion` are
  keyword-positive on 0/120 records.
- Corrupted variants: US calorie extraction drops from 60/60 to 45/48 scored
  (digit corruption is the dominant failure); keyword detection is mostly
  robust (57/60 on Canadian labels).

These gaps are pinned by XCTests in `SwiftReplay` so a parser change that moves
them is visible in CI. Fixing them is parser work, not corpus work — the corpus
is the measuring stick, and was not adjusted to make the parser look better.

## Determinism

For a fixed seed the corpus is byte-stable; the Swift replay report is stable
too (`ReplayTests` pins both). Regenerating with `--seed 20261010` reproduces
the committed `corpus/labels.jsonl` exactly.
