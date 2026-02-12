# USDA Curation Context Compaction (Detailed)

## Project Purpose
FridgeLuck is a recipe-first app. Ingredient data should support:
- realistic home-cooking ingredient search,
- nutrition lookup per 100g,
- flexible user text matching via aliases,
- clean UI labels (human-readable, English-only),
- practical variants (e.g., chicken breast vs thigh, milk fat variants, all-purpose flour).

The dataset is **not** intended to be a catalog of branded ready-to-eat products.

## Hard Constraints
- Preserve nutrition macro integrity (`calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sodium_g`).
- Metadata passes (display names, aliases, clarifications) must not mutate existing macro rows.
- English-only naming/aliases.
- Keep category filtering recipe-relevant, but allow practical cooking items (e.g., rotisserie chicken, mayo, dressings, heavy syrup variants when they can be ingredients).
- Enable search on official name + aliases.

## What Was Previously Completed
1. USDA catalog generation switched to USDA API-first flow (no manual fixed 50 list).
2. Macro extraction corrected and hydrated via batch detail endpoint.
3. Sodium unit fixed to grams (`sodium_g`) across scripts.
4. Recipe-focused curation + dedupe + category labeling implemented.
5. App-bundled SQLite export created and loader integrated.
6. Alias table support added to app DB and repository search.
7. First manual override batch added (55 targeted entries including `luffa` and all-purpose flour naming).

## Current Data Pipeline (as of this compaction)
- Raw USDA cache: `scripts/data/.cache/usda_common_food_catalog.json`
- Curation CLI: `scripts/data/usda.py` (`uv run usda ...`)
- Manual overrides: `scripts/data/usda_manual_overrides.json`
- Chunked review outputs: `scripts/data/.cache/review_chunks/`
- Final clean JSON: `scripts/data/.cache/usda_cooking_ingredient_catalog_clean.json`
- Final SQLite: `FridgeLuck.swiftpm/Resources/usda_ingredient_catalog.sqlite`

## Key Technical Decisions
- Keep USDA `fdc_id` as stable identity.
- Add metadata columns for search quality:
  - `display_name`
  - `alt_names`
  - `clarification`
  - `search_text`
- Add `ingredient_aliases` table in SQLite and import aliases into app DB.
- Search path includes ingredient name + notes + aliases.

## Known Gaps Identified Before This Pass
- Some display names had collision suffixes like `(3)`.
- Some aliases contained formatting artifacts from parenthetical parsing.
- Some high-frequency items were missing from first-page catalog slice (e.g., soy sauce, black pepper, chicken thigh/tender variants).
- Need recursive backfill pass for common missing ingredients.

## New Workflow Direction (Requested)
1. Context compaction first (this file).
2. Run batch workflow in terminal for 50-row curation chunks.
3. Improve aliases/descriptions for each chunk.
4. Add recursive missing-item backfill to raw catalog from USDA search/detail.
5. Rebuild curated outputs while protecting macro data for existing rows.

## Safety Rules for Ongoing Passes
- No manual override keys for macro fields.
- Existing macros must remain unchanged unless explicitly permitted for a controlled migration.
- Missing ingredient additions append new FDC rows only.
- Every pass emits review chunks to continue iterative curation.

## Immediate Next Execution Steps
- Upgrade metadata generation quality (display/alias cleanup + better disambiguation).
- Add macro immutability guard in builder.
- Run recursive common-item backfill script.
- Rebuild and validate:
  - row count,
  - missing-common-item checks,
  - alias coverage,
  - no macro drift for existing `fdc_id`.

## Latest Completed Pass (Current)
- Added strict targeted backfill mode (`--only-extra-queries`, `--add-fdc-id`, query variants actually used, batched `/foods` detail fetch).
- Ran `.env`-driven USDA backfill and appended missing staple rows directly to raw cache (e.g., canned tuna, black beans, olive oil, skim-milk source row).
- Expanded parser rules so important variants do not collapse:
  - milk fat variants (`1%`, `2%`, skim, whole, evaporated vs fluid),
  - pepper variants (black/red/white),
  - green onions/scallions,
  - canned tuna,
  - rotisserie cut variants,
  - frozen peas.
- Added large manual override pass for 50 weak rows plus additional cleanup (final overrides count: 148).
- Rebuilt outputs with macro immutability guard active:
  - curated JSON rows: **799**
  - SQLite `ingredients` rows: **799**
  - SQLite `ingredient_aliases` rows: **2245**
- Coverage check for critical queries now positive:
  - `canned tuna`, `olive oil`, `black beans`, `frozen peas`,
  - `2% milk`, `1% milk`, `skim milk`, `whole milk`,
  - `black pepper`, `red pepper flakes`,
  - `green onion`, `scallion`,
  - `all-purpose flour`, `rotisserie chicken`.
