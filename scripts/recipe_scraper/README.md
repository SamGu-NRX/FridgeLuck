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
