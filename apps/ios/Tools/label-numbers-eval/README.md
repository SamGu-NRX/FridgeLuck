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
- `SwiftReplay/` — Swift package that replays the production parser over the corpus
- `strict_baseline.py` — rigid line-anchored comparison arm (no joining, no tolerance)
- `reports/replay_predictions.jsonl` — committed per-record production-parser outputs (Swift dump)
- `reports/strict_predictions.jsonl` — committed per-record strict-baseline outputs
- `score_report.py` — scores both arms against truth; writes `reports/report.json`
- `reports/report.json` — committed scoring report (field/unit/basis + abstention accounting)
- `verify_report.py` — recomputes and byte-compares the committed report
- `tests/` — pytest suite for generator, checker, scorer, and verifier (`python3 -m pytest tests -q`)

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

# regenerate the committed prediction + report files
swift run label-numbers-replay --predictions ../reports/replay_predictions.jsonl
cd .. && python3 strict_baseline.py && python3 score_report.py
python3 verify_report.py           # exits 0 when the committed report matches
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

## Scoring and accounting

`score_report.py` treats every truth entry as a probe and assigns exactly one
status, in precedence order:

| status | meaning |
|---|---|
| `unobservable` | the entry is not observable (or has no value) — never scored |
| `unavailable` | the arm has no extractor for this field at all |
| `unavailable_basis` | field supported, but not on this basis (e.g. `energy_kcal@per_100g`) |
| `untouched` | production only: the keyword gate excluded the record — no attempt |
| `abstention` | the arm attempted but returned no value; production abstains per record (`parsed == null`), so a calories failure also nulls serving size and servings per container |
| `match` / `mismatch` | value comparison (calories ±0.5, servings ±0.01, serving size normalized string) |

A production calorie number is compared against each observable serving-like
truth entry separately: matching `per_serving` and missing `per_package` are
two honest outcomes of one number, not one. The committed
`reports/report.json` carries per-arm totals, per family/variant breakdowns,
and explicit field × unit × basis tables (e.g. `energy_kcal`, `kcal`,
`per_serving`), plus `unsupported_production_fields` (the six fields the
parser does not extract: `energy_kj`, `fat_g`, `carbohydrate_g`, `protein_g`,
`sodium_mg`, `salt_g` — marked `unavailable`, not scored as abstentions) and
`untouched_formats_production` (family|variant cells the keyword gate never
attempts: all four EU cells).

All counters are integers, so the committed bytes are stable;
`verify_report.py` recomputes from the committed corpus + predictions and
byte-compares — any edit to any of the four files fails it.

## Full-accounting results

5,590 probes per arm (480 records × their truth entries):

| status | production | strict baseline |
|---|---|---|
| match | 218 | 436 |
| mismatch | 103 | 0 |
| abstention | 355 | 355 |
| untouched | 115 | — (no gate) |
| unavailable_basis | 314 | 314 |
| unavailable | 2,721 | 2,721 |
| unobservable | 1,764 | 1,764 |

Production, per field: calories on `per_serving` 208 match / 3 abstain
(the strongest number the parser has); serving size 10 match / 103 mismatch /
119 abstain — the greedy overrun costs ~100 records that a plain line capture
gets; servings-per-container 0-for-233 attempted — the phrase-order assumption
voids the field entirely. The strict baseline matches 436 with zero
mismatches: on clean US labels it captures serving size exactly (113) and
counts servings (115) where the production parser fails; the strict tool's
misses are corrupted digits and EU `Energy` lines it refuses to guess. The
production parser wins nothing over it on this corpus — its calorie matches
are identical (208), and every other gap is its own. The strict arm is not a
straw man either: it abstains rather than guessing on corrupted digits and EU
`Energy` lines, which is why it never mismatches.

## Handoff

- **Committed evidence**: `corpus/labels.jsonl`, `reports/replay_predictions.jsonl` (Swift dump, seed-independent), `reports/strict_predictions.jsonl`, `reports/report.json`. The report records the sha256 of corpus and both prediction files.
- **One-command re-check**: `python3 verify_report.py` — recomputes and byte-compares; exits 0 only on committed, unmodified inputs.
- **Regeneration order**: `python3 generate_corpus.py --seed 20261010` → `swift run label-numbers-replay --predictions reports/replay_predictions.jsonl` → `python3 strict_baseline.py` → `python3 score_report.py` → `python3 verify_report.py`. The Swift step is the only non-Python step and runs on Linux or macOS.
- **Production code untouched**: `NutritionLabelParser.swift` was not modified to cover the benchmark; the replay ships a byte-identical copy under `SwiftReplay/Sources/LabelNumbersReplay/`.
- **Open items** (in rough value order): (1) serving-size capture overrun — the single largest production loss (~100 records); (2) servings-per-container phrase order — voids the field on every label of this shape; (3) EU support — both EU families are keyword-gate untouched, and `energy_kj`/per-100g extraction is `unavailable`; (4) whole-record abstention — a calories failure discards otherwise-extractable serving-size/servings values.
- **Unchecked surface**: macOS/iOS build and the XCTests under Apple CI (no Xcode in this environment); the Linux Swift run covers the same test sources.

## Determinism

For a fixed seed the corpus is byte-stable; the Swift replay report is stable
too (`ReplayTests` pins both). Regenerating with `--seed 20261010` reproduces
the committed `corpus/labels.jsonl` exactly.
