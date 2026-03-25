# BBC Good Food Recipe Scraper

Scrapes recipes from:

- `https://www.bbcgoodfood.com/recipes/collection/quick-and-healthy-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-dinner-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-lunch-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-vegetarian-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-pasta-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-salad-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/low-calorie-dinner-recipes`
- `https://www.bbcgoodfood.com/recipes/collection/healthy-chicken-recipes`

Outputs a single JSON array in this schema:

- `source_url`
- `title`
- `servings_original`
- `servings_target`
- `ingredients: [{ raw, scaled_raw, name, amount_value, amount_unit, prep_actions }]`
- `steps: [string, ...]`

The app's bundled GRDB seed (`apps/ios/Resources/data.json`) uses a different schema:

- fixed `ingredients` dictionary keyed by numeric ID
- `recipes` as positional arrays with required/optional ingredient ID + grams pairs

Use the merge command below to transform scraped output into that shape safely.

Ingredient normalization notes:

- `name` is a simplified canonical ingredient name (`2 x 175g packs chargrilled artichokes` -> `artichokes`).
- `amount_value` stores measurable quantity as an integer where possible (for example `350` with `amount_unit: "g"`).
- `prep_actions` contains inferred prep verbs from action adjectives (`chargrilled`, `roasted`, `sliced`, `diced`, `chopped`, etc.).
- Prep actions may also be prepended to `steps` as short instructions when that action is not already present in method text.

## Setup (uv)

```bash
cd scripts/recipe_scraper
uv sync
```

## Run

```bash
uv run scrape-recipes run --out .cache/bbc_goodfood_recipes.json --target-servings 2
```

Optional quick test run:

```bash
uv run scrape-recipes run --max-recipes 10
```

The output file is deterministic JSON and written atomically.

## Merge Into GRDB Seed Shape (Non-Destructive)

Transforms scraper output into bundled `data.json` recipe-array format while:

- keeping existing ingredient rows untouched
- appending recipes only (no overwrite)
- de-duping on canonical recipe title and `Source:` URL
- skipping recipes that do not map enough ingredients to known IDs
- validating base `data.json` shape before writing
- writing a diagnostics report for unmatched ingredients and skipped rows

```bash
uv run scrape-recipes merge-grdb \
  --scraped .cache/bbc_goodfood_recipes.json \
  --bundled-data ../../apps/ios/Resources/data.json \
  --out .cache/data.merged.non_destructive.json \
  --report-out .cache/merge_report.json
```

To overwrite `data.json` directly (not recommended until reviewed), add `--in-place`.
