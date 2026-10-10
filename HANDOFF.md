# Handoff: household-mass evidence — state/packing matching, conversion checks, drift verification

Follow-up to the initial FNDDS household-measure evidence work on
`obv/fl-l2-mass-evidence` (draft PR #50, base `obv/fl-next-nutrition-reference`).
The production estimator (`InventoryIntakeService`) remains **unmodified**.

## What changed

### 1. Preparation-state and packing labels on the pinned table

`extract_household_measures.py` now classifies each portion's qualifier text
(portion description + modifier) and writes optional `state` and `packing`
columns into `mass_conversion_table.json`:

- `state`: `cooked` | `dried` | `raw` | `frozen` | `thawed` — priority order
  first-hit-wins, so "prepared from frozen, heated" labels `frozen`. Word
  boundary matching. `"not reconstituted"` (instant coffee, powdered milk)
  labels `dried`; plain `reconstituted` labels `cooked`.
- `packing`: `canned` | `jarred` | `packaged`.

Result on the pinned FNDDS 2024-10-31 data: 7,288 conversions unchanged,
558 state labels (438 cooked, 79 dried, 41 raw), 0 packing labels — FNDDS
portion text simply carries no container language. `fndds_household_units.csv`
gained `grams_per_unit` (the per-unit grams the conversion table is built
from); its row content is otherwise identical.

### 2. MassConversionKit: state-aware matching, evidence, ranges

`MassConversionKit` (the pure-Foundation package the app will consume):

- `convert(food:unit:state:packing:)` prefers entries whose `state`/`packing`
  match the query's detected preparation state (detected from the query text
  with the same priority/negation rules); falls back to unlabeled entries.
- Explicit `ConversionEvidence`: `exact` (full token coverage both ways) vs
  `partial` (token overlap, incomplete coverage). Unknown conversions return
  `nil` — never fabricated.
- `parseQuantity` handles ranges ("1/2 - 1 cup" → mean magnitude) and vulgar
  fractions ("½"); `lowGrams`/`highGrams` carry the range endpoints when the
  source magnitude was a range.

### 3. Conversion checks (`swift run conversion-checks`)

Two deterministic checks over the pinned table, reported in
`conversion_checks.{json,md}`:

- **Held-out recovery**: every 10th entry withheld, matcher must recover its
  grams from remaining entries. 729 withheld → 711 recovered (9 exact,
  702 partial evidence, 18 unknown), median relative error 0.0%, mean 32.7%,
  563 within ±25% / 650 within ±50% (duplicate `(food, unit)` magnitudes make
  exact-grams recovery the norm even when evidence is partial).
- **100-meal yield**: 100 census meals × 3 ingredients, intake-style
  three-word queries. 100/100 meals fully converted, 100.0% ingredient yield.
  **Honest caveat** (also stated in the report): prefix queries always
  token-overlap their source description, so this check validates the
  end-to-end conversion path, not name-resolution difficulty. Real-world
  coverage of partial user input is unmeasured.

### 4. Driver fixes (`evaluate_mass_estimates.py`)

- Removed the hardcoded `/home/user/swift612/usr/bin/swift` path —
  `SWIFT_BIN` env var, then `PATH` lookup.
- The reports' estimator stamp is now the estimator source's **git blob SHA**
  instead of current HEAD, so regenerating on unrelated commits no longer
  churns committed files.
- The driver now also runs `conversion-checks` and writes its reports.
- New `--verify-report` flag: regenerates every committed output and
  byte-compares; exits 1 naming drifted files. Verified:
  `verify-report: all committed outputs byte-identical`.

## Verification performed

- `python3 -m pytest scripts/data/tests/` — 72 passed (incl. new
  `TestPreparationStateClassifier` unit tests).
- `swift test` (package, Linux, Swift 6.1.2) — 28/28 passed.
- `python3 scripts/data/evaluate_mass_estimates.py` — estimator arms
  reproduced exactly: 176 examples, nameArm median 113% / unitArm 77% /
  unitPrefixed 72%, within-50% counts 46/55/67 — the 176-row measured
  results are preserved; only the provenance stamp line changed.
- `--verify-report` — byte-identical (see above).

## Not verified / known limits

- **No Xcode/iOS build**: `MassConversionKit` is validated on Linux Swift
  only; the hosted macOS CI run on PR #50 is the check for Apple-platform
  compilation.
- Meal-yield coverage is self-fulfilling by construction (see §3); treat it
  as a plumbing check.
- Packing labels are absent because FNDDS portion text has no container
  language; the column exists so future sources can populate it.
- `--verify-report` re-runs extraction only when the FNDDS cache exists
  (fresh clones skip it, and `mass_conversion_table.json` absence counts as
  drift).
- The `state` classifier is keyword-based and deliberately conservative;
  labels are advisory metadata for matching preference, not ground truth.

## Reproduce

```bash
python3 -m pytest scripts/data/tests/ -q
cd apps/ios/Tools/mass-conversion-check && swift test
python3 scripts/data/evaluate_mass_estimates.py --verify-report
```
