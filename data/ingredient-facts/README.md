# data/ingredient-facts

Canonical ingredient-fact dataset for FridgeLuck. Owned by the `overhaul/ingredient-facts`
branch (draft PR into `alpha`). Read by the `FLIngredientFacts` Swift package and mirrored
independently by the TypeScript and Python conformance runners.

## Files

- `identities.json` — canonical ingredient keys → display name, synonyms/aliases,
  USDA FDC id (from `apps/ios/Resources/usda_ingredient_catalog.sqlite` and
  `scripts/data/catalog`), app local ids (from the `ingredients` map in
  `apps/ios/Resources/data.json`), and preparation forms (a form is a distinct
  entry when its facts differ, e.g. generic tamari vs certified gluten-free tamari).
- `facts.json` — per canonical key: components (for compounds) with a certainty level
  (`certain` / `typical` / `variable` / `unknown`) and evidence; allergen facts; diet
  facts.
- `conformance/cases.json` — shared JSON cases (ingredient, restrictions, expected
  result) that Swift, TypeScript and Python consumers each run.
- `conformance/runners/typescript/run_conformance.ts` — Bun runner.
- `conformance/runners/python/run_conformance.py` — Python runner.

## Rules

- A variable or unsourced property is `unknown`, never `false`.
- Every non-unknown fact carries evidence: `{"kind", "ref", "note"}` with kind one of
  `usda` (fdc id), `label` (product claim), `reference`, `recipe`, `standard`.
- Evidence must be real: cite the catalog row, document, recipe corpus entry or label
  claim it came from. Never invent an fdc id or URL.
- The nine FDA major allergens (milk, egg, fish, crustacean shellfish, tree nuts,
  peanuts, wheat, soy, sesame) plus gluten as a separate property. Diets: vegetarian,
  vegan, pescatarian, gluten-free, dairy-free.
- Generic tamari is not gluten-free without product evidence; stock cubes and bouillon
  vary by product, so their uncertain facts stay unknown.

## Sources

- `apps/ios/Resources/usda_ingredient_catalog.sqlite` (`ingredient_catalog` table:
  `fdc_id`, `normalized_name`, `alt_names_json`, …)
- `scripts/data/catalog` (catalog build scripts and overrides)
- `apps/ios/Resources/data.json` (bundled: 166 recipes, 50 core ingredients)
- Original recipe corpora on `fleet/fl-recipe-originals*` branches
- Product label claims, cited as such
