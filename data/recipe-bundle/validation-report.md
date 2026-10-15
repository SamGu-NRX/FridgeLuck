# Recipe bundle v2 — integration validation report

Date: 2026-10-15 · Branch: `obv/burst5-fridgeluck-rcp-integrate` · Base: `obv/burst5-fridgeluck-rcp-loader`

## What shipped

- `apps/ios/Resources/RecipeCatalog/recipes-v2.json` — the compiled bundle
  (763 recipes, 329 ingredients), byte-identical to `data/recipes/build/recipes-v2.json`
  (sha256 `87f4f2c1…99eb7f`, 2,603,827 bytes). The app target's resource glob
  (`apps/ios/Resources` in `project.yml`) picks the file up with no project changes.
- `data/recipe-bundle/manifest.json` — provenance, contents, and verification evidence.
- `data/recipe-bundle/ingest_packets_2026_10.py` + `data/recipes/evidence/ingest-2026-10-map.json`
  — the packet ingestion tool and its packet-id → corpus-id mapping.
- `apps/ios/Tests/Integration/RecipeCatalogIntegrationTests.swift` — end-to-end tests
  against the *shipped* bundle.

## How the bundle was produced

```
python3 data/recipe-bundle/ingest_packets_2026_10.py --write   # 362 ingested, 2 excluded
python3 data/recipes/tools/build_vocab.py                      # 329 keys, 555 surfaces, +97 fdc rows
python3 -m pytest data/recipes/tools/tests/test_pipeline.py -q # 14 passed
python3 data/recipes/tools/compile_bundle.py                   # 763 recipes, 329 ingredients
python3 data/recipes/tools/validate_bundle.py                  # PASS
```

Corpus: PR #113's 401-recipe corpus plus the two originals packets — the world packet
(PR #164, 177 of 179 ingested) and the everyday packet (PR #163, 24 authored originals +
161 re-authored legacy-#144 rewrites). Packet ids were renumbered into the corpus's
`fl-original-*` band (the compiler derives catalog ids from the id suffix; packet
suffixes would collide) with the packet → corpus mapping recorded in
`ingest-2026-10-map.json`; each packet's rights manifest was converted into the main
manifest shape with evidence pointing at the packet files and commits. Nothing recipe-level
was authored or edited.

**Dedupe:** two world-packet recipes were excluded, never retitled — `fl-world-0043`
"Egg Drop Soup" and `fl-world-0147` "Chicken Enchiladas Rojas" share normalized titles
with existing corpus dishes that are different recipes (different ingredients, times,
servings). The corpus versions ship; the packet versions stay in-repo with the exclusion
recorded in the mapping file.

**Vocabulary:** rebuilt with the pipeline's own `build_vocab.py` over the extended corpus
(/tmp/canon identities + /tmp/fdc FNDDS/SR CSVs as before). Verified additive in the
ways that matter: `per_100g` and `fdc_id` are unchanged for all 220 pre-existing keys;
only unit weights and aliases were recomputed. 97 new keys (mostly world-cuisine
specialties) have no FNDDS per-100g row, so their recipes carry honest *partial*
nutrition coverage rather than synthesized values.

**Determinism:** compiled twice — byte-identical. `GENERATED_AT` bumped to
`2026-10-15T12:45:00Z` per the compiler's recompile instruction. The pipeline test that
pins the corpus size was updated 401 → 763.

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
  reserved and absent), so nothing supersedes the legacy rows yet. The everyday packet's
  161 re-authored legacy-#144 rewrites are *new* catalog rows (`rcp-000750`+), not
  in-place successors; wiring them as successors is a catalog-layer decision to make
  later, and until then the legacy rows stay.

Retirement therefore happens where the spec puts it: legacy rows are superseded at the
catalog layer (quarantined, display-only, excluded from sharing; a v2 successor bumps
the revision in place). Actual deletion from `data.json` becomes possible only when a
bundle ships migrated successors for all 166 legacy recipes **and** recommendation gains
a catalog-backed query path. Revisit then. Legacy ids stay resolvable throughout.

## Contract note for the spec owners

The everyday packet's categories (breakfasts, packed-lunches, 20-minute-dinners, …) do
not fit the bundle-v2 `collections` enum (`quick`, `budget`, `one_pot`, `comfort`,
`use_soon`). Widening a spec-owned contract is not an integration call, so the
categories ship as packet-level metadata in `ingest-2026-10-map.json` and the recipes
carry no collection tags. If the enum should grow, that is a schema change (PR #148).

## Upstream state

- PRs #163/#164 (the packets) are still open as drafts; this branch carries their
  branches merged in so the corpus, vocabulary, and bundle are self-consistent here.
- PR #151 (loader) CI was failing on loader-thread compile errors when last checked;
  this PR's CI cannot pass until the base compiles.

## Not verified here

- Nothing Swift was compiled locally (no toolchain in this environment); the hosted
  macOS CI run on this PR is the first real compile of the new test target.
- `validate_corpus.py` needs a `conversions.json` the extracted suite does not carry;
  corpus-level linting of the ingested records ran through the packets' own checkers
  and the compiled-output validator instead.
- Bundle size impact on the app binary (2.6 MB resource) is unmeasured beyond file size.
