# Catalog rebuild — burst12 (2026-10-16)

Rebuild of the shipped recipe catalog from the reviewed corpus-fix packets
(#195 amounts-a, #196 amounts-b, #197 rubric) and the merged 2026-10
breakfast/pantry original batches (#201, #203), under fail-closed rights
revisions and fail-closed diet claims. Branch:
`obv/burst12-fridgeluck-catalog-rebuild`.

## What ran

1. `data/recipes/tools/apply_corpus_fixes.py` — applied all 189 fixes
   (86 amounts-a, 85 amounts-b, 18 rubric) to `data/recipes/corpus.jsonl`.
   Every fix's `before_sha256` matched its pinned corpus line in one dry run;
   nothing skipped. Ten fixes flagged `changes_rights_pin` (titles, added
   structural lines, a molasses line) carry pinned FridgeLuck revisions in
   `data/recipes/evidence/rights.json` (`fl_revisions`): the recipes stay
   LicenseRef-FL-Original — FridgeLuck's own edit of its own text — and the
   rights gate accepts them only when the pinned revision describes the shipped
   record exactly (title, ingredient-name hash, full-body hash).
2. `data/recipes/tools/strip_unproven_claims.py` — removed exactly one claim
   the composition gate cannot prove corpus-wide: `fl-original-0341`
   (rcp-000507) no longer claims vegetarian, because the rubric fix added a
   `banana` line the suite allergen table does not resolve. The revision pins
   tolerate claim-list edits only; `stripped_claims` records the removal.
3. `data/recipes/tools/compile_bundle.py` — fail-closed claims now ship:
   an authored true diet claim survives only when the line composition classes
   prove it; unprovable claims ship null; a proven-true vegan claim requires
   proven vegetarian and dairy_free (compile refuses otherwise).
   `validate_bundle.py` audits both rules.
4. Rebuilt `data/recipes/build/recipes-v2.json`, mirrored byte-identically to
   `apps/ios/Resources/RecipeCatalog/recipes-v2.json`; regenerated both
   manifests against the new file (they had drifted apart — each pinned a
   different bundle sha before this branch).

## Diet claims in the rebuilt bundle (true/false/null)

| claim | shipped | rebuilt | change |
|---|---|---|---|
| vegetarian | 327/333/102 | 325/333/104 | 2 true→null |
| vegan | 121/585/56 | 120/585/57 | 1 true→null |
| gluten_free | 336/314/112 | 335/314/113 | 1 true→null |
| dairy_free | 306/282/174 | 303/282/177 | 3 true→null |

Seven claim flips on five recipes (`rcp-000179`, `-000190`, `-000199`,
`-000207`, `-000532`), all true→null; no recipe gained a true claim.

## Bundle facts after the fix rebuild (pre-ingestion state)

- 762 recipes, 328 ingredients, catalog band rcp-000167..rcp-000934,
  rights 762 original / 0 quarantined.
- Nutrition coverage: 164 computed, 489 estimated, 109 partial.
- 1170 steps carry `timer_seconds`; 468 thermometer checks (0 auto-added).
- sha256 `3a7101850a1ca4980b85611cb03c513461c33946755b7c97d5d99e31c39d3d26`
  (2,700,638 bytes), generated_at pinned `2026-10-16T09:30:00Z`;
  compile is byte-identical across 3 repeat runs
  (MD5 c70c21c742b345539cb1da553a39a261).

## Catalog reach rerun (reach_report_v3.py)

Rerun over the rebuilt bundle. Before/after use the same committed app-side
catalog SQLite (`apps/ios/Resources/usda_ingredient_catalog.sqlite`, restored
to its tracked state), so the delta isolates the recipe-data rebuild.
Median diet-eligible cookable recipes across the ten pantries:

| diet | before exact | after exact | before near | after near |
|---|---|---|---|---|
| omnivore | 1.5 | 4.5 | 108.5 | 160.5 |
| vegetarian | 0.5 | 1.5 | 58.5 | 91.0 |
| vegan | 0.0 | 0.0 | 23.5 | 29.0 |
| gluten_free | 0.0 | 2.5 | 47.5 | 75.5 |
| dairy_free | 0.0 | 2.0 | 49.5 | 76.5 |

Lost required lines (before-state classification): 0 pantry names without an
app ingredient, 2044 lines landing on a same-food different id (207 recipes),
1220 lines without a bridge (48 recipes), 28131 genuinely not in the kitchen.

## Checks

- `validate_corpus.py`: GREEN (rights, quarantine, release gates, dedupe, lint).
- `validate_bundle.py`: PASS (439 informational null-claim warnings, 0 errors).
- `pytest data/recipes/tools/tests/`: 48 passed, 1 skipped; 1 pre-existing
  kcal-drift failure — `data/recipe-bundle/nutrition-changes-2026-10.json`
  carries stale `new_kcal` entries; the same test fails on the alpha tip, so
  it is not introduced by this branch. Regenerating that file is owned by the
  amounts packets' follow-up (#205's nutrition-record rebuild).
- Taste-lab fixtures regenerated with the lab's own command
  (`python3 -m taste_lab regenerate-fixtures --seed 7`); replay-verified;
  lab tests 19 passed.

## Not done here

- The reach report outputs land in `/tmp` (evaluation/catalog-reach is not an
  owned path on this task); the numbers above are the record.
- `data/recipe-bundle/nutrition-changes-2026-10.json` regeneration (not owned;
  described above and in the PR body).
