# Learn-cards tools

How the nutrition layer for `data/kitchen-knowledge/learn-cards/` is built.
Everything here is reproducible offline except the SR Legacy download.

## Files

- `universe.py` — derives the card universe (50 core ingredients from
  `apps/ios/Resources/data.json` + seed-corpus ingredients from
  `origin/eval/scorecard-runner`, merged per `MERGE`) and writes
  `universe.json`.
- `fdc_map.csv` — the curated `card_id -> fdc_id` mapping, one row per card,
  with a one-line rationale for every choice. Cards with an empty `fdc_id`
  ship WITHOUT `nutritionPer100g` (refused rather than guessed).
- `emit_nutrition.py` — reads `fdc_map.csv` plus the local SR Legacy CSV
  download and emits `nutrition_out.json`. Nutrient ids were verified against
  `nutrient.csv` in the download; note vitamin A RAE is id 1106 (id 1104 is
  vitamin A in IU, not RAE).
- `nutrition_out.json` — emitted blocks (checked into git for auditability).
- `build_cards.py` — merges `prose/<id>.json` content with universe metadata
  and `nutrition_out.json` into `cards/<id>.json` and `index.json`.
- `validate.py` — the pre-push gate; run from repo root:
  `python3 data/kitchen-knowledge/learn-cards/tools/validate.py`

## SR Legacy release

USDA FoodData Central, SR Legacy CSV release 2018-04 (file
`FoodData_Central_sr_legacy_food_csv_2018-04.zip`), downloaded 2026-10-11 from
<https://fdc.nal.usda.gov/download-datasets/>. SR Legacy is a frozen,
public-domain dataset; the download is NOT committed (keep it in /tmp).

## Refused mappings (no nutrition block)

chaat_masala, flattened_rice, garam_masala, gochujang, halloumi, harissa,
paneer, rice_vinegar — no honest SR Legacy row exists; see the rationale
column in `fdc_map.csv`.
