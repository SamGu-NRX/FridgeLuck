# Recipe bundle v2 — integration validation report

Date: 2026-10-15 · Branch: `obv/burst5-fridgeluck-rcp-integrate` · Base: `obv/burst5-fridgeluck-rcp-loader`

## What shipped

- `apps/ios/Resources/RecipeCatalog/recipes-v2.json` — the compiled bundle (401 recipes,
  218 ingredients), byte-identical to `data/recipes/build/recipes-v2.json`
  (sha256 `24d5f083…8eac7`, 1,476,178 bytes). The app target's resource glob
  (`apps/ios/Resources` in `project.yml`) picks the file up with no project changes.
- `data/recipe-bundle/manifest.json` — provenance, contents, and verification evidence.
- `apps/ios/Tests/Integration/RecipeCatalogIntegrationTests.swift` — end-to-end tests
  against the *shipped* bundle.

## How the bundle was produced

```
python3 -m pytest data/recipes/tools/tests/test_pipeline.py -q   # 14 passed
python3 data/recipes/tools/compile_bundle.py                      # 401 recipes, 218 ingredients
python3 data/recipes/tools/validate_bundle.py                     # PASS
```

Compiled from PR #113's corpus (`data/recipes/corpus.jsonl`, 401 recipes) with the
pipeline branch's compiler (PR #158, `compile_bundle.py` at `3644321`). Determinism was
verified by recompiling and comparing hashes — byte-identical. The validator checks
JSON-Schema conformance, ingredient references, nutrition plausibility (Atwater
cross-check), fail-closed dietary claims, rights evidence, and FSIS thermometer rules.

## End-to-end tests (run by hosted macOS CI)

`RecipeCatalogIntegrationTests` reads the bundle the app actually ships (`Bundle.main`,
via `RecipeBundleV2Loader.bundleV2URL`), not a fixture, and proves:

1. **Full hydration** — every bundle recipe lands in `recipes_catalog` with at least one
   structured line and one structured step, every line's ingredient key resolves in the
   vocabulary, every revision has its nutrition snapshot, catalog ids stay in the corpus
   band (lowest `rcp-000167`), rights statuses stay within the audited set, and a second
   apply changes nothing (launch idempotence).
2. **v18 upgrade keeps history** — a database migrated to `v18_cooking_history_swaps`
   with legacy ingredients, a bundled recipe, and cooking history keeps both history
   rows and the legacy recipe row while the bundle hydrates fully around it; no catalog
   row claims a legacy id (this bundle has no migrated successors, so a link would be a
   misattribution).
3. **Recommendation over the migrated database** — `RecommendationEngine.findRecipes`
   over fixture pantries: an egg pantry returns the omelette as an exact match with
   `matchedRequired == totalRequired` and nothing missing; a tomato-only pantry returns
   no exact match and a near match that names exactly the missing egg; the empty-pantry
   fallback still reports honest fit lines; the catalog read path serves the shipped
   bundle's structured content through `RecipeRepository`.

## Legacy rows in `apps/ios/Resources/data.json` — decision

**Kept, deliberately.** The spec decides that legacy recipes "stay readable through
their existing ids" and that a successor must keep its id for cooking history to
resolve. Three hard constraints make deleting the 166 legacy recipe rows from
`data.json` a break, not a cleanup, at this point:

- The loader links a v2 successor to its legacy row by querying the legacy `recipes`
  table (`source = 'bundled'` + matching title); no row, no link, no history resolution.
- `RecommendationEngine.findRecipes` queries the legacy `recipes`/`recipe_ingredients`
  tables, which are hydrated from `data.json`; the catalog layer has no recommendation
  query path yet, so removing legacy rows would make fresh installs recommend nothing.
- This bundle contains no migrated legacy successors (`rcp-000001..rcp-000166` are
  reserved and absent), so nothing supersedes the legacy rows yet.

Retirement therefore happens where the spec puts it: legacy rows are superseded at the
catalog layer (quarantined, display-only, excluded from sharing; a v2 successor bumps
the revision in place). Actual deletion from `data.json` becomes possible only when a
bundle ships migrated successors for all 166 legacy recipes **and** recommendation gains
a catalog-backed query path. Revisit then. Legacy ids stay resolvable throughout.

## Pending upstream

- The two `data/recipe-sources/` batches (originals-world / originals-everyday) had not
  landed when this bundle was compiled; `manifest.json` records them as pending. When
  they arrive: ingest into the corpus, recompile, revalidate, update the manifest, push.
- The base PR's `build-and-test` check was still red (loader-thread compile errors,
  iterating); this PR's CI cannot pass until the base compiles — my branch carries the
  same loader code unchanged.

## Not verified here

- Nothing Swift was compiled locally (no toolchain in this environment); the hosted
  macOS CI run on this PR is the first real compile of the new test target.
- Bundle size impact on the app binary (1.5 MB resource) is unmeasured beyond file size.
