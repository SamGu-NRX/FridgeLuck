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
- `strict_baseline.py` — rigid line-anchored comparison arm covering all nine fields (no joining, no tolerance)
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

## Evaluation protocol (frozen)

- **Frozen family split**: development = `us_dual_column`, `ca_bilingual`;
  heldout = `eu_per100g`, `eu_per_portion`. Every arm's metrics are reported
  per frozen split (`by_split` in the report).
- **Prior exposure is disclosed**: all four families were examined during tool
  development — the generator, truth tables, production-gap measurements, and
  the strict baseline's patterns were all written after inspecting every
  family's line shapes. The heldout designation is frozen to keep future arm
  changes honest; it is **not** a clean held-out split, and heldout metrics
  are confirmatory, not discovery.
- **Keyword-rejected records are not evaluation**: records the production
  keyword gate rejects are excluded from its totals entirely and disclosed as
  `gate_rejected_records` / `gate_rejected_formats` (with per-cell counts).
  They are not scored as "untouched" probes — no comparison happens on them.

## Scoring and accounting

Each arm is scored against its **own declared capability**; the production
whitelist is not imposed on the strict baseline:

- production: `energy_kcal` (per_serving/per_portion), `serving_size`,
  `servings_per_container`. The six other corpus fields are marked
  `unavailable` — explicit missing coverage, never silently dropped.
- strict_baseline: all nine fields on the bases its rigid patterns produce
  (EU per-100g/per-100ml/per-portion declarations; US/CA per-serving lines).

Per-probe status, first match wins: `unobservable` (entry not observable —
never scored) → `unavailable` (arm has no extractor for the field) →
`unavailable_basis` (field supported, basis not) → `abstention` (attempted,
no value; production abstains per record) → `match`/`mismatch` (calories
±0.5, kJ ±2.0, mass ±0.05, sodium ±10, servings ±0.01, serving size
normalized string).

A production calorie number is compared against each observable serving-like
truth entry separately: matching `per_serving` and missing `per_package` are
two honest outcomes of one number.

**Controls** (diagnostics per arm; they do not change the statuses):

- `unit_errors` — mismatch whose value equals the truth under a unit
  conversion (kcal↔kJ ×4.184, mg↔g ×1000): right quantity, wrong unit.
- `basis_errors` — mismatch whose value equals a different observable basis
  entry of the same field: right number, wrong column.
- `false_abstentions` — abstentions on probes the companion arm matched:
  values extractable from the committed text that the arm threw away.

All counters are integers, so the committed bytes are stable;
`verify_report.py` recomputes from the committed corpus + predictions and
byte-compares — any edit to any of the four files fails it.

## Results

Probe pools: strict baseline 5,590 (all 480 records, all nine fields);
production 2,733 (237 keyword-admitted records — the gate rejects 243:
all 240 EU records and 3 corrupted Canadian records, disclosed per cell).

| status | production | strict baseline |
|---|---|---|
| match | 218 | 2,255 |
| mismatch | 103 | 0 |
| abstention | 355 | 389 |
| unavailable_basis | 110 | 1,182 |
| unavailable | 1,226 | 0 |
| unobservable | 721 | 1,764 |
| controls: unit / basis / false-abstention | 0 / 0 / 125 | 0 / 0 / 0 |

Frozen splits: production — development 2,733 probes (all of it; heldout
empty because the gate rejects both EU families), strict — development 646
match / 237 abstain, heldout 1,609 match / 152 abstain. The strict baseline's
0 mismatches are by construction: it abstains on corrupted digits and EU
`Energy` lines rather than guessing, which is why every non-match is an
abstention.

Production, per field (development records only): calories on `per_serving`
208 match / 3 abstain — its one strong field, identical to the strict tool's
208; serving size 10 match / 103 mismatch / 119 abstain (the greedy overrun
costs ~100 records a plain line capture gets); servings-per-container 0-for-233
attempted (the phrase-order assumption voids the field). The 125 false
abstentions are values the strict tool extracts from the same committed text
that production's whole-record abstention discarded. The six unavailable
fields (1,226 probes) and EU coverage are the parser-repair backlog this
corpus pins; the strict baseline now demonstrates that every one of those
fields is recoverable by rigid line extraction on clean labels.

## Handoff

- **Committed evidence**: `corpus/labels.jsonl`, `reports/replay_predictions.jsonl` (Swift dump, seed-independent), `reports/strict_predictions.jsonl` (extended nine-field extractor), `reports/report.json` (schema v3: frozen protocol, per-arm capability, splits, controls). The report records the sha256 of corpus and both prediction files.
- **One-command re-check**: `python3 verify_report.py` — recomputes and byte-compares; exits 0 only on committed, unmodified inputs.
- **Regeneration order**: `python3 generate_corpus.py --seed 20261010` → `swift run label-numbers-replay --predictions reports/replay_predictions.jsonl` → `python3 strict_baseline.py` → `python3 score_report.py` → `python3 verify_report.py`. The Swift step is the only non-Python step and runs on Linux or macOS.
- **Production code untouched**: `NutritionLabelParser.swift` was not modified to cover the benchmark; the replay ships a byte-identical copy under `SwiftReplay/Sources/LabelNumbersReplay/`.
- **Open items** (in rough value order): (1) serving-size capture overrun — the single largest production loss (~100 records); (2) servings-per-container phrase order — voids the field on every label of this shape; (3) EU support — both EU families are keyword-gate rejected and `energy_kj`/per-100g extraction is `unavailable`; the strict baseline shows all of it is rigidly extractable; (4) whole-record abstention — a calories failure discards otherwise-extractable values (125 false abstentions against the strict arm); (5) a genuinely held-out format family, since all four current families were development-exposed.
- **Unchecked surface**: macOS/iOS build and the XCTests under Apple CI (no Xcode in this environment); the Linux Swift run covers the same test sources.

## Determinism

For a fixed seed the corpus is byte-stable; the Swift replay report is stable
too (`ReplayTests` pins both). Regenerating with `--seed 20261010` reproduces
the committed `corpus/labels.jsonl` exactly.
