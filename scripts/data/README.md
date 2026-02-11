# Data Scripts

## USDA ingredient nutrition collector

Script: `scripts/data/fetch_usda_ingredient_nutrition.py`

This collector uses the official USDA FoodData Central API to gather nutrition data for the app's bundled ingredient list (`FridgeLuck.swiftpm/Resources/data.json`), then outputs a compact USDA-shaped nutrition dataset.

### Prerequisite

Install the USDA client in a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install usda-fdc
```

### Usage

```bash
export USDA_FDC_API_KEY="<your_key>"
python3 scripts/data/fetch_usda_ingredient_nutrition.py
```

Optional flags:

```bash
python3 scripts/data/fetch_usda_ingredient_nutrition.py \
  --ingredient-limit 20 \
  --max-candidates 12 \
  --delay-sec 0.15 \
  --parallelism 6 \
  --cache-file scripts/data/.cache/usda_fdc_response_cache.json \
  --catalog-file scripts/data/.cache/usda_common_food_catalog.json \
  --catalog-target 1500 \
  --catalog-max-pages 25 \
  --out FridgeLuck.swiftpm/Resources/usda_ingredient_nutrition_compact.json
```

Fast full refresh (recommended):

```bash
python3 scripts/data/fetch_usda_ingredient_nutrition.py \
  --parallelism 8 \
  --delay-sec 0.1 \
  --cache-file scripts/data/.cache/usda_fdc_response_cache.json \
  --catalog-file scripts/data/.cache/usda_common_food_catalog.json \
  --catalog-target 1500 \
  --catalog-refresh
```

Generate Swift static data:

```bash
python3 scripts/data/generate_usda_ingredient_swift_static.py \
  --in-json FridgeLuck.swiftpm/Resources/usda_ingredient_nutrition_compact.json \
  --out-swift FridgeLuck.swiftpm/Data/Static/USDAIngredientNutritionStaticData.swift
```

Notes:
- The collector is intentionally conservative: low-confidence USDA matches fall back to existing bundled values.
- `matched_count` in the output indicates how many ingredients were confidently matched.
- Bootstraps a large USDA catalog first (default 1500 rows from `foods/list`) and uses USDA-native labels (`dataType`, `foodCode`) during matching.
- Uses the large catalog for primary matching, then targeted USDA search/detail fallback for misses.
- Stores API search/detail responses in an on-disk cache to dramatically speed reruns.

## USDA cooking-ingredient curation + SQLite export

Script: `scripts/data/build_usda_catalog_sqlite.py`

Purpose:
- Repairs/rehydrates macro fields from USDA detail endpoints.
- Filters out non-home-cooking entries (prepared/commercial categories and noisy rows).
- Keeps only meaningful columns for app usage.
- Exports both clean JSON and SQLite.
- Generates a markdown visualization report for quick QA.

Run:

```bash
export USDA_FDC_API_KEY="<your_key>"
python3 scripts/data/build_usda_catalog_sqlite.py \
  --in-catalog scripts/data/.cache/usda_common_food_catalog.json \
  --out-json scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json \
  --out-sqlite FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite \
  --out-report scripts/data/.cache/usda_cooking_ingredient_catalog_report.md
```

Outputs:
- Clean JSON: `scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json`
- App-usable SQLite: `FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite`
- Visualization report: `scripts/data/.cache/usda_cooking_ingredient_catalog_report.md`

### Ethical collection notes

- Uses API access instead of scraping HTML pages.
- Uses a descriptive `User-Agent`.
- Includes a request delay for polite usage.
- Keeps source attribution in output records.

### Sources

- USDA FoodData Central API Guide: <https://fdc.nal.usda.gov/api-guide>
- USDA FoodData Central Download Data: <https://fdc.nal.usda.gov/download-datasets>
- USDA Food Data Central Python Client docs: <https://usda-fdc.readthedocs.io/en/latest/>
