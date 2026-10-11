# Handoff: household-mass evidence — food-group-held-out checks, yield sensitivity, packing scan

Follow-up r2 on the FNDDS household-measure evidence work on
`obv/fl-l2-mass-evidence` (draft PR #50, base `obv/fl-next-nutrition-reference`).
The production estimator (`InventoryIntakeService`) remains **unmodified** —
the estimator replay is still a read-only slice of its source.

r1 (preparation-state/packing labels, every-10th-entry held-out recovery) was
reworked in r2 per review: the held-out protocol is now **food-group-held-out**
(entire WWEIA categories withheld), a source-bound **cooking-yield sensitivity**
arm was added, packing evidence is exercised and explicitly declared
**unmeasured**, and the 100-meal check is labeled a **conversion-path plumbing
check**, not a yield study.

## What changed in r2

### 1. WWEIA category on the pinned table (existing evidence kept intact)

`extract_household_measures.py` writes each conversion entry's WWEIA food
category. Regeneration preserved all 7,288 entries with their grams, food,
state, and packing fields — the only diff vs the previous table is the added
`category` field (verified programmatically). 558 state labels (438 cooked /
79 dried / 41 raw) and 0 packing labels are unchanged; MANIFEST hashes
regenerate. `MassConversionKit` decodes the optional `category` on
`ConversionEntry`; the conversion lookup, quantity/evidence/unknown contract,
and matching preference logic are unchanged. The bundled resource stays
byte-equal to the pinned file (resource-sync test).

### 2. Food-group-held-out recovery (replaces the every-10th-entry split)

The r1 split withheld every 10th entry, which left other records of the same
food in the lookup and overstated recovery. r2 withholds **entire WWEIA
categories**: 167 arms; per arm the category's entries are removed from the
table and every withheld entry is queried against the remaining table. Per
arm: n, matched, unknown, exact, partial, median/mean relative error,
within ±25% / ±50% — plus a pooled aggregate, all committed in
`conversion_checks.{json,md}`.

Aggregate across the 167 arms: 7,288 withheld → 6,731 matched (2 exact,
6,729 partial evidence), 557 unknown; median relative error 20.6%, mean
76.3%; 3,658 within ±25%, 5,059 within ±50%. The degradation vs r1's leaky
split (711/729 recovered, median 0.0%) is the honest number: with the whole
category gone, recovery genuinely gets harder, and the report says so.

### 3. Cooking-yield sensitivity arm (source-bound; NOT the meal check)

`scripts/data/evaluate_mass_estimates.py` derives raw/cooked survey-food
pairs: same WWEIA category, equal normalized description stems (state words
removed), sharing a canonical household unit whose per-unit grams differ
(first household-units row per `(fdc_id, unit)` — the conversion table's
dedup order). Ratio = cooked grams per unit ÷ raw grams per unit; per-unit
energy/macros come from SurveyFoods per-100g anchors (208 kcal / 203 protein
/ 204 fat / 205 carbohydrate) of each side. Results in
`yield_sensitivity.{json,md}`:

- 22 pairs across 9 WWEIA categories; ratio spread 0.600 – 1.736 (median) –
  4.250; per-unit kcal delta −27.0 to +159.3 (median +61.5).
- Examples: Chard raw 36 g/cup → cooked 150 g/cup (ratio 4.167, +59.2 kcal
  per cup); Apple raw 125 g/cup → baked 190 g/cup (1.520, +138.4 kcal);
  Broccoli raab raw 40 g/cup → cooked 170 g/cup (4.250, +69.4 kcal); Banana
  raw 225 g/cup → baked 140 g/cup (0.622 — a mass-loss case, +7.2 kcal).
- 7 candidate pairs are recorded as explicit **missing inputs** (all "no
  shared unit with differing grams": salmon raw/grilled/fried/steamed, tuna,
  garlic, hot peppers, fennel) — never filled.

The ratio is an observed mass-yield factor between two survey-food records,
not a universal cooking rule, and nothing in `MassConversionKit` applies a
yield factor — this arm quantifies how far per-unit energy and macros move
between raw and cooked forms of the same food stem.

This arm is **not** the 100-meal check: successful conversion of the
generated three-food bundles is conversion-path plumbing, not a yield study
(see §5).

### 4. Packing evidence: exercised, and declared unmeasured

A word-boundary scan over the full FNDDS portion description+modifier text
(22,194 portions, `packing_scan.{json,md}`) counts: bag 342, can 261,
bottle 218, package 204, pouch 123, jar 54, tub 53, box 45, canned 4,
carton 2, pack 2. Of the 8,319 portions that parse into canonical household
units: can 152, package 83, canned 1, pack 1 — container words are the
portion's own **quantity units** ("1 can (5 oz) yields"), not packing
qualifiers on the grams. Exactly one qualifier-level hit exists (Corned beef
hash, "1 cup, canned", fdcId 2706477) and it loses the `(food, unit,
magnitude)` dedup to an earlier unlabeled row, so the pinned table carries
**0 packing labels**. Conclusion, stated plainly in the report: FNDDS
attaches no packing evidence to household portions; packing matching in
`MassConversionKit` is exercised only by synthetic unit tests, so packing
generalization is **unmeasured**.

### 5. 100-meal check relabeled

`conversion_checks.{json,md}` now label the 100 census-meal check
"conversion-path plumbing check (NOT a yield study)": 100/100 meals fully
converted, 100.0% conversion rate. Prefix queries always token-overlap their
source description, so the check validates the end-to-end conversion path
(unit choice, lookup, evidence levels), not name resolution or yield.

## Verification performed

- `python3 -m pytest scripts/data/tests/ -q` — **89 passed** (r1: 72), now
  covering stem normalization, yield-pair derivation (including missing-input
  cases), the packing scan, and the committed report structures.
- `swift test` (package, Linux, Swift 6.1.2) — **31 tests, 0 failures**
  (r1: 28), adding category-decoding coverage.
- `python3 scripts/data/evaluate_mass_estimates.py --verify-report` —
  regenerates the extractor outputs, estimator replay, LOCO conversion
  checks, yield-sensitivity arm, and packing scan, then byte-compares
  everything: **"verify-report: all committed outputs byte-identical"**,
  exit 0.
- Conversion-table diff vs the previous commit: only `category` added;
  7,288 entries, all grams unchanged; bundled resource byte-equal to the
  pinned file.
- Estimator evaluation untouched: 176 examples, nameArm median 113% /
  unitArm 77% / unitPrefixed 72%, within-50% 46/55/67 — byte-identical.

## Output hashes (committed r2 outputs)

| File | SHA-256 |
|---|---|
| `mass_conversion_table.json` | `e02260441784b14bc4859305f8c12dfa34833ed255bda894f2c324758da4acbf` |
| `conversion_checks.json` | `54f71a80b39440c35c5ef370e977aaf89efacc011bf1c5fe591f9ce9a2724cab` |
| `conversion_checks.md` | `39920d4c8900d0ff28b0cb6491457b1200f9718f578d704fed9d3af9854d0d85` |
| `yield_sensitivity.json` | `73af7352798d8f2eed91e064cf9e92d17649cc83834cc893d795f121ef54c6a8` |
| `yield_sensitivity.md` | `4bf696fa1647d1ef3e4ac83958cf6afa10d0d543af563e7c7fe62e3d1412f0ef` |
| `packing_scan.json` | `ea37ed24fd60899e124f3c6a2f0c2874be38705f5c4ae512b5aa44b36f9ee1bf` |
| `packing_scan.md` | `1cc20641e0af6761b6303e8c1055f1c3fe46d4228a481b019d62c00a1d27ce27` |
| `main.swift` (checks tool) | see `git rev-parse HEAD:apps/ios/Tools/mass-conversion-check/Sources/conversion-checks/main.swift` |

## Not verified / known limits

- **No Xcode/iOS build**: `MassConversionKit` is validated on Linux Swift
  only; the hosted macOS CI run on PR #50 is the check for Apple-platform
  compilation.
- Yield ratios are source-bound observations between survey-food records,
  not universal cooking rules; no yield factor is applied in the kit.
- Packing generalization is unmeasured (see §4) — synthetic tests only.
- Meal conversion coverage is self-fulfilling by construction (§5); treat it
  as a plumbing check.
- `--verify-report` re-runs extraction only when the FNDDS cache exists
  (fresh clones skip it, and `mass_conversion_table.json` absence counts as
  drift).
- The `state` classifier remains keyword-based and conservative; labels are
  advisory metadata for matching preference, not ground truth.

## Reproduce

```bash
python3 -m pytest scripts/data/tests/ -q
cd apps/ios/Tools/mass-conversion-check && swift test
SWIFT_BIN=<swift 6.1+ on PATH> python3 scripts/data/evaluate_mass_estimates.py --verify-report
```
