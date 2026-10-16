# everyday-2026-10 — everyday recipes slice (RS v1)

185 recipes in two groups, all `rs_version: "1"`, same record shape as the PR #113
corpus (`data/recipes/corpus.jsonl` on `obv/burst5-fridgeluck-spec-recipes`):

- `originals.jsonl` — 24 recipes authored for this slice (IDs `fl-everyday-0001…0024`).
  Written for the eight everyday categories (breakfasts, packed-lunches,
  20-minute-dinners, budget-student-pantry, high-protein, vegetarian-vegan-mains,
  batch-leftovers, sides-salads) with balance bars: every category represented,
  all six cuisines, breakfast/lunch/dinner slots, and a recipe in each cook-time
  band (≤15, 16–30, 31–45, 46–60, 61+ min). 18 of 24 are vegetarian (≥ 1/3 bar).
- `converted-144.jsonl` — 161 re-authored RS v1 records for the 161 legacy recipe
  records of PR #144 (IDs 167–327, snapshotted in `legacy-144.json`), balanced over
  the same eight categories. Rewrites keep each legacy record's ingredient set and
  core dish identity; titles and cook-facing step text are newly written.

## Evidence and checks

- `evidence/conversions-pinned.json` — household→grams conversion table pinned from
  the #113 suite (`26c7004`), 129 rows. Household quantities must cite a
  `conversion_ref` with `grams` within 2% of `value × grams_per_unit`.
- `evidence/allergen-classes.json` — 128 ingredient aliases pinned from the same
  suite; drives vegetarian/vegan computation and safety-class assignment.
- `tools/check_everyday.py` — slice checker: RS v1 shape, ingredient resolution
  (USDA catalog + canonical vocabulary), household gram fidelity, category/diet
  balance, step/ingredient integrity, safety wording per class, reheat+leftovers
  rule, rights evidence, and duplicate (title, core-ingredient-set) pairs. Its
  adapter runs the pinned corpus validator with slice rights-evidence forms.
- `tools/test_check_everyday.py` — planted-failure tests for the checker.
- `tools/gen_rights.py` — regenerates `rights_manifest.json` and
  `evidence/rights.json` from the shipped recipe files.
- `evidence/rights.json` — per-recipe license/source-type/permissions/title plus
  ingredient-name hashes; per-file sha256. All records are
  `LicenseRef-FL-Original` (authored or rewritten for FridgeLuck; FSIS citations
  for safety steps).
- `report.md` — validation run record.

## Reproduce

From the slice directory (`data/recipe-sources/everyday-2026-10` in a
FridgeLuck checkout):

```
python3 tools/test_check_everyday.py

python3 tools/check_everyday.py --dir . \
  --catalog ../../../apps/ios/Resources/usda_ingredient_catalog.sqlite \
  --bundled ../../../apps/ios/Resources/data.json \
  --corpus113 <#113 checkout>/data/recipes/corpus.jsonl \
  --legacy144 legacy-144.json
```

`--legacy144` takes PR #144's shipped `apps/ios/Resources/data.json` shape
directly (its `recipes` array of `[id, title, minutes, servings, ingredients,
tags, instructions, ...]` rows is normalized in the checker) or the equivalent
title-keyed map. `--corpus113` is PR #113's `data/recipes/corpus.jsonl`
(branch `obv/burst5-fridgeluck-spec-recipes`). Omitting one of the external
inputs does not fail the run, but every skipped check is printed as a
`SKIPPED` line and counted in the summary, so a green `0 error(s)` is always
explicit about what was and was not verified. The catalog is required and
fails closed. The full gate, including the pinned suite validator (extract
the suite revision `26c7004` and the #113 checkout, then):

```
python3 tools/check_everyday.py --dir . \
  --catalog ../../../apps/ios/Resources/usda_ingredient_catalog.sqlite \
  --bundled ../../../apps/ios/Resources/data.json \
  --corpus113 <#113 checkout>/data/recipes/corpus.jsonl \
  --legacy144 legacy-144.json \
  --validate-suite <suite checkout at 26c7004> \
  --corpus-tools <#113 checkout>/data/recipes/tools
```

The USDA FoodData Central / FNDDS catalog database used for ingredient
resolution is the repository's `apps/ios/Resources/usda_ingredient_catalog.sqlite`;
the checker resolves through it and reports unresolved names rather than
guessing. `report.md` records the latest validation run.
