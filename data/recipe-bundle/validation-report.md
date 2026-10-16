# Recipe bundle v2 — integration validation report

Date: 2026-10-15 · Branch: `obv/burst5-fridgeluck-rcp-integrate` · Base: `obv/burst5-fridgeluck-rcp-loader`

## What shipped

- `apps/ios/Resources/RecipeCatalog/recipes-v2.json` — the compiled bundle
  (762 recipes, 328 ingredients), byte-identical to `data/recipes/build/recipes-v2.json`
  (sha256 `96d9896a…d8439`, 2,600,354 bytes). The app target's resource glob
  (`apps/ios/Resources` in `project.yml`) picks the file up with no project changes.
- `data/recipe-bundle/manifest.json` — provenance, contents, and verification evidence.
- `data/recipe-bundle/ingest_packets_2026_10.py` + `data/recipes/evidence/ingest-2026-10-map.json`
  — the packet ingestion tool and its packet-id → corpus-id mapping.
- `apps/ios/Tests/Integration/RecipeCatalogIntegrationTests.swift` — end-to-end tests
  against the *shipped* bundle.

## How the bundle was produced

```
python3 data/recipe-bundle/ingest_packets_2026_10.py --write   # 361 ingested, 3 excluded
python3 data/recipes/tools/build_vocab.py                      # 329 keys, 555 surfaces, +97 fdc rows (operator-only inputs)
python3 -m pytest data/recipes/tools/tests/test_pipeline.py data/recipes/tools/test_gates.py -q
python3 data/recipes/tools/compile_bundle.py                   # 762 recipes, 328 ingredients
python3 data/recipes/tools/validate_bundle.py                  # PASS (32 disclosed warnings)
python3 data/recipes/tools/validate_corpus.py                  # VALIDATION GREEN
```

Corpus: PR #113's 401-recipe corpus plus the two originals packets — the world packet
(PR #164, 176 of 179 ingested) and the everyday packet (PR #163, 24 authored originals +
161 re-authored legacy-#144 rewrites). Packet ids were renumbered into the corpus's
`fl-original-*` band (the compiler derives catalog ids from the id suffix; packet
suffixes would collide) with the packet → corpus mapping recorded in
`ingest-2026-10-map.json`; each packet's rights manifest was converted into the main
manifest shape with evidence pointing at the packet files and commits. Nothing recipe-level
was authored or edited.

**Dedupe and food-safety exclusions:** three world-packet recipes were excluded, never
retitled or re-authored — `fl-world-0043` "Egg Drop Soup" and `fl-world-0147` "Chicken
Enchiladas Rojas" share normalized titles with existing corpus dishes that are different
recipes (different ingredients, times, servings), and `fl-world-0135` "Curry Goat" failed
the fail-closed FSIS gate (the chart has no goat row, so its protein cannot be verified).
The corpus versions ship; the exclusions are recorded in the mapping file.

**Review-fix round (2026-10-15):** the five review findings on this PR were addressed —
the bundle validator's diet-claim audit now reads the vocabulary's real per-key `classes`
and fails on expressible contradictions (seeded vegetarian-on-chicken: FAIL; unknown
vocabulary coverage is disclosed as warnings, the corpus composition gate remaining the
fail-closed authority); the release gate runs on the committed tree and is green
(762 recipes, rights clear, linter 401/401, 0 unchecked claims); the byte-identity test no
longer needs operator `/tmp` inputs and instead proves the committed build copy equals a
fresh compile; the packet checker's suite modules are committed under the packet's `src/`;
and `.github/workflows/python-ci.yml` now runs the pipeline tests and all release gates on
every PR. Four corpus recipes were corrected for fail-closed FSIS evidence (thermometer
checks on Chicken Kyiv, Bigos, Leczo; an unsupported temperature claim removed from Koose),
and Curry Goat was excluded as above, which is why the corpus is 762, not 763.

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

---

# Addendum — 2026-10-15 nutrition-completion revision (branch `obv/burst6-fridgeluck-recipe-nutrition`)

The bundle was recompiled after a vocabulary revision that resolves 51 specialty keys
(mostly world-cuisine) to same-product FDC rows in the FNDDS 2024-10-31 / SR Legacy
2018-04 bulk CSVs — e.g. hoisin → Hoisin sauce 2707441, oyster sauce ("hao you") 2707150,
salt cod 174190, borlotti beans → cranberry (roman) beans 173736, daikon → oriental
radish 168451. Every pin cites the row's own description and is the same product as the
key; keys whose only candidate rows are a different product (gochujang, mirin, labneh,
dashi, halloumi, species-unspecified stock, …) stay unresolved with their rejected
candidates recorded in `data/ingredients/unresolved-candidates.json`, and
`build_vocab.py` now fails if that audit drifts from the vocabulary. The legacy identity
map is fully resolved (32 resolved / 18 proposed / 0 unresolved; `tortilla` resolves via
the plural key `tortillas`).

Effect on the shipped bundle (sha256 `d442a11f…3edcbc2`, 2,611,873 bytes, `GENERATED_AT`
`2026-10-15T16:46:35Z`): nutrition coverage moved from 163 computed / 345 estimated /
255 partial to **164 computed / 500 estimated / 99 partial**. 193 recipes changed kcal
(median +11.5); the 33 recipes that moved more than 40 percent are the previously
under-reported ones, and each carries a recorded cause in
`data/recipe-bundle/nutrition-changes-2026-10.json` naming the resolved keys in its
lines. The validator gained a `--previous`/`--changes` kcal-drift check that fails on
any unrecorded >40% move between published bundles, with planted-violation tests in
`data/recipes/tools/tests/test_kcal_drift.py`.

Nothing recipe-level was authored or edited; all changes flow from the audited
vocabulary revision through the pipeline's own rebuild.

## fix-168 rebuild — rights labels and legacy links (2026-10-15, this branch)

The rights manifest's 461 `original` / 302 `original-rewrite` records met a bundle-v2
schema that only knows `original | quarantined`, and the compiler collapsed
`original-rewrite` to `quarantined` on compile — cleared rewrites shipped labelled as
if their rights were unknown. This branch:

- Decides the shipped `rights.status` from the release gate's per-recipe verdict
  (`validate_corpus.recipe_rights_errors`, now also exposed as
  `cleared_and_quarantined` / `load_rights_context`), not from `source_type`: every
  rights-cleared FL original/original-rewrite ships `original` — 762 of 762; nothing
  ships `quarantined`.
- Adds `validate_bundle.check_rights_statuses`: the validator re-runs the gate and
  refuses any shipped `original` the gate does not clear (plus anything outside the
  enum). Planted-violation tests in `data/recipes/tools/tests/test_rights_status.py`
  prove it fails closed.
- Attaches `legacy_id` to bundled ingredients from `legacy-ingredient-map.json`
  `resolved` entries only (49 of 50; alias resolution: legacy `tortilla` → key
  `tortillas`, `chickpea` → `chickpeas`). 17 formerly `proposed` entries were promoted
  after reviewing FDC row descriptions (fetched from the FoodData Central API this
  session); legacy `banana` (id 20) stays unlinked — its only candidate, FDC 169394,
  is "Pepper, banana, raw", a banana pepper, not the fruit. The vocabulary key
  `banana` (display "Banana") ships that pepper row as its FDC row, so its identity
  needs re-examination; nothing under the `banana` key is re-pinned here, the finding
  is recorded in the map and the manifest notes.
- Drops Curry Goat (excluded by the merge) from the kcal-drift exemptions: the changes
  file is regenerated against the ac5a535 bundle — 32 exemptions, no `rcp-000705`.
- Manifest refreshed (counts, sha256 `0d8fa0f4…fa72ba`, 2,607,234 bytes, legacy-link
  block) and shipped as a sidecar at
  `apps/ios/Resources/RecipeCatalog/manifest.json`; new
  `RecipeCatalogManifestIntegrityTests` re-derive the hash, byte count, and every
  provenance count from the shipped bytes on CI.

Verification: `validate_corpus.py` VALIDATION GREEN · `validate_bundle.py` PASS
(rights: 762 original, 0 quarantined; gate clears 762; 0 label problems) · drift check
PASS with 0 unrecorded problems · `pytest` 77 passed, 1 skipped · three rebuilds
byte-identical (MD5 `ed2d8444f7b94af18aeea9a4997fca29`).
