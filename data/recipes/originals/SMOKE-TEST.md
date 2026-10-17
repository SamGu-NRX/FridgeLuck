# Scaffold smoke test - evidence log

Date: 2026-10-11. Branch: `fleet/fl-recipe-originals` (from `alpha` 2e779381bb39).
Purpose: prove the corpus toolchain end to end with two real exemplar recipes
before any writer threads start. Every command below is replayable.

## Exemplar recipes

| File | Part | What it exercises |
|---|---|---|
| `part1-rewrite/rw-ginger-egg-fried-rice.json` | part1-rewrite | rewrites bundled id 1 (Classic Egg Fried Rice); `replaces` link; egg safety check at 160F; `bundled_id` nutrition source; use-it-up:rice |
| `east-southeast-asian/ea-chicken-larb-lettuce-cups.json` | east-southeast-asian | original dish; ground-poultry safety at 165F (strict compound table); part conversion shard; fdc nutrition source; gluten-free/dairy-free/nut-free claims; salty-unmapped sodium flag |

Both pass with `hard=0, soft=0`, rights-clear, `resolved-lines=100.0%`.

## Positive results (clean tree)

```
$ python3 data/recipes/originals/tools/validate.py --all
TOTAL: 2 recipes, rights-clear=2, pass=2, hard=0, soft=0

$ python3 data/recipes/originals/tools/nutrition.py --check --all
nutrition check: 2 block(s) verified, 0 mismatch(es)

$ python3 data/recipes/originals/tools/dedupe.py
dedupe: 2 originals, 0 exact-duplicate titles, 0 near-duplicate warning(s)

$ python3 data/recipes/originals/tools/bundled.py --titles --dump /tmp/bundled-recipes.json
decoded 166 bundled recipes (166 with titles), 50 core ingredients
```

Computed nutrition (USDA + data.json sources, evidenced grams):

- ginger egg fried rice: 556 kcal, 17.8 g protein, 663 mg sodium/serving,
  coverage 0.997, sodium flagged (`salt` unmapped)
- chicken larb: 363 kcal, 33.1 g protein, 117 mg sodium/serving, coverage
  0.922, sodium flagged (`fish sauce` unmapped - real fish sauce would add
  ~1.3 g/serving, so the 117 must not be shown as a trustworthy number)

## Negative controls (planted failures, one at a time)

Restored from backup after each. Every planted class was caught:

| Planted failure | Gate that fired |
|---|---|
| copy a recipe with the same title under a new id | `dedupe.py`: DUPLICATE title |
| `conversion_ref: "egg_carton_dozen"` (not in any table) | suite R2: "household measure has no conversion in the table (invented mass)" |
| safety object removed from an egg recipe | validator: "SAFETY: ['egg'] present but no matching thermometer check with the FSIS temperature" |
| `rs_version: "rs/9"` | suite R1: "rs_version must be '1'" |
| rights-manifest record emptied | validator RIGHTS: no rights-manifest record |
| recipe dropped into the wrong part dir | validator ID-PREFIX + CUISINE |
| `sodium_basis`/`sodium_unmapped_salty` stripped while fish sauce unmapped | validator NUTRITION: "sodium_unmapped_salty [] != recomputed ['fish sauce']" |
| fish sauce hand-mapped to the tamari row while the flag stays | validator NUTRITION: "sodium_unmapped_salty ['fish sauce'] != recomputed []" |

## Data findings recorded during the smoke test

1. **fdc 168883 "White Rice (Cooked)" is mislabeled** - its macros are
   dry-rice values (370 kcal, 81.7 g carbs per 100 g). Unusable; recipes
   measure rice dry. Documented in AUTHORING.md and part1 notes.
2. **No plain whole-egg row exists in the bundled catalog** - eggs map to
   the app's own data.json table via `bundled_id`.
3. **Bundled "Healthy chilli con carne" computes 11,165 mg sodium/serving**
   from its own ingredient lines (bundled.py math) - a data anomaly for the
   Part 1 rewrite attention list.
4. **Catalog sodium is stored as g/100g** (verified against soy sauce 5.586
   and rice 0.007); the nutrition tool converts to mg.
5. The suite's allergen scanner matches ingredient names EXACTLY against its
   alias table ("thai basil" misses "basil"), so core ingredients must use
   canonical alias names; the strict compound layer carries part-specific
   names and doneness enforcement for them.

## Known limitations (honest gaps)

- `test_status` is `untested` on both exemplars: no kitchen cook-through has
  happened. That field stays honest until a human cooks one.
- The larb's sodium number is flagged incomplete (fish sauce); consumers of
  the corpus must respect the flag.
- The RS-to-RecipeRevision ingestion question for the app remains open
  (README "Open questions"); RS is the authoring format meanwhile.
