# Household-measure reference tables (USDA FNDDS)

Pinned evidence for converting household measures (cup, tbsp, slice, egg, ...)
to grams, extracted from the USDA FoodData Central Survey Foods dataset
(FNDDS 2021-2023, published 2024-10-31).

## Files

| File | What it is |
|---|---|
| `fndds_portions.csv` | Every FNDDS survey-food portion with a positive gram weight (22,193 rows): `fdc_id`, `food_description`, `category`, `portion_description`, `modifier`, `gram_weight`. |
| `fndds_household_units.csv` | The 8,319 portions whose `portion_description` parses to a canonical household unit (`cup`, `tbsp`, `tsp`, `floz`, `oz`, `slice`, `piece`, `egg`, ...), with `magnitude` and `grams_per_unit`. |
| `mass_conversion_table.json` | Deduplicated `(food, unit, magnitude) -> grams` conversions consumed as the bundled resource of the Swift `MassConversionKit` package (`apps/ios/Tools/mass-conversion-check`). |
| `estimator_examples.json` | 176 deterministic source-bound examples used to evaluate the production `InventoryIntakeService` gram estimator. |
| `estimator_evaluation.csv` | Per-example estimator results and errors across three arms. |
| `estimator_evaluation.md` | Human-readable evaluation report. |
| `MANIFEST.json` | Provenance: source URL, archive and JSON SHA-256, edition, row counts, unit inventory. |

## Regeneration

```bash
# Requires the cached FNDDS JSON in scripts/data/.cache/surveyDownload.json
# (see MANIFEST.json for the URL and hashes).
python3 scripts/data/extract_household_measures.py

# Regenerates the estimator replay slice + examples, runs the Swift replay,
# and rewrites the evaluation CSV/MD (requires a Linux Swift 6.1+ toolchain).
python3 scripts/data/evaluate_mass_estimates.py
```

Both scripts are deterministic for identical inputs (the manifest records a
generated-at timestamp only).

## Provenance

- Dataset: USDA FoodData Central Survey Foods (FNDDS), edition 2024-10-31
- URL: https://fdc.nal.usda.gov/fdc-datasets/foodData_513.surveyDownload.json.zip?cachebust=2024103101
- Archive SHA-256: `dfb06ae7ddc397ccd570b91c14b75438ab2ba39f64f22d321f61d4a52a77f3eb`
- Unpacked `surveyDownload.json` SHA-256: `2e7eb9fda92adf1d4d784dba5eaa3a7fd4418cd86ccff383c7c9294d79e9b808`
- 5,432 survey foods; 22,193 positive-weight portions; 8,319 (37%) resolve to
  a canonical household unit. Unparsed descriptions are dominated by
  non-modeled forms: "Quantity not specified", "1 cubic inch", "1 miniature",
  "1 individual container".

## Tests

- `scripts/data/tests/test_household_measures.py` — binds the tables to the
  source edition and to known USDA portion weights (1 tbsp oil = 14 g, 1 egg
  = 50 g, 1 cup whole milk = 244 g, ...).
- `apps/ios/Tools/mass-conversion-check` — pure-Foundation `MassConversionKit`
  API with contract tests on the bundled table (Linux-runnable), plus a sync
  test that fails if the bundled resource drifts from the pinned file.
