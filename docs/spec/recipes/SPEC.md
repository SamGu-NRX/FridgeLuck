# Recipe system spec — identity, bundle v2, corpus contracts

Status: draft for review · Branch `obv/burst5-fridgeluck-spec-recipes` · 2026-10-15

This spec fixes the data contracts for the recipe system's next iteration: canonical
ingredient identity, the versioned recipe bundle, and the taste-signal event envelope.
It is the contract layer under the recipe drafts already in review (#113 corpus, #144
expansion, #62 search, #114 substitutions, #127 ingredient facts, #126 food safety) and
the contract boundary for taste learning (PR #146, `docs/spec/taste/`), which owns the
profile and the residual ranker — not the events.

**Load-bearing assumption.** The drafts assume that recipe lines, inventory rows, and
USDA-resolved scans can be joined by one canonical ingredient identity, and that fixing
the vocabulary removes the identity-mismatch class of bugs (recipe lines vs. catalog
rows never shared a dependable id on `alpha` — traced through `BundledDataLoader.swift`,
`BundledDataLoaderUSDACatalog.swift`, `IngredientCatalogResolver.swift`,
`RecipeRepository.swift`). Evidence for the fix: the identity map below resolves every
legacy id against the bundled catalog. What would break the premise: if per-line
context (preparation state, brand) turns out to matter more than identity for ranking
and allergen checks — then the canonical key stays but the join key moves, and this
spec's identity section is revised rather than extended.

## 1. Ingredient identity

`apps/ios/Resources/data.json` carries 50 legacy ingredients (ids 1–50). The bundled
USDA catalog (`usda_ingredient_catalog.sqlite`, 800 rows, FDC ids) does not preserve
legacy ids. `contracts/examples/ingredient-identity-map.sample.json` is the generated
map; the rules, in order:

1. **resolved** — exactly one display-name or alias match (3,998 aliases in the
   catalog): 13 ingredients. Examples: `olive_oil` → FDC 171413, `soy_sauce` → 174278.
2. **proposed** — no exact match, but exactly one prefix/stem candidate and its
   qualifiers do not change the food (reject salted/frozen/juice/dressing/flour/
   parfait/yogurt/pepper/bread/… forms): 10. Examples: `lime` → 168155, `cumin` →
   170923 (Cumin Seed), `chickpea` → 2644282 (dry — pipeline confirms form), `apple`
   → 168202 (Golden Delicious only — qualifier confirmed against full FDC before
   shipping).
3. **unresolved** — no acceptable candidate: 27, including all the multi-variant
   foods (`milk`, `cheese`, `mushroom`, `lettuce`, `yogurt`, `sweet_potato`) and the
   misdirection traps (`egg` — only catalog row is salted/frozen, recorded as
   candidate but never auto-resolved; `banana` — only hit is Banana Pepper; `tofu` —
   only hit is Tofu Yogurt).

Unresolved entries are **not invented**. The pipeline resolves them against full
FoodData Central (CC0) and pins source + query in `verification_source`, mirroring the
catalog's own verification columns. Every entry records all candidates considered, so
the audit trail survives review.

The canonical vocabulary is the ingredient `key` (stable slug), with `fdc_id` and
`legacy_id` as nullable evidence links. Nothing in the app joins on integer ids.

## 2. Recipe bundle v2

`contracts/recipe-bundle-v2.schema.json` — the shape of the shipped, versioned bundle
(`bundle_version: 2`). Succeeds the 166-row eight-field legacy recipes, which stay
readable through their existing ids; bundle v2 rows carry stable `catalog_id`
(`rcp-NNNNNN`) plus `revision`. Existing recipe ids and cooking-history references
must survive the migration: a legacy recipe's successor keeps its id and bumps
`revision` (the sample shows `rcp-000002` at revision 2, rewritten as an original
after the #43 rights audit).

What the schema enforces, fail-closed:

- **Quantities** are one of `grams`, `count`, `household`, or `unknown` (with a
  human note). A household line carries grams only when the conversion is evidence-
  backed (MassConversionKit / #50); `unknown` is for "to taste", never a guessed
  gram value.
- **Steps** reference ingredients by index (`uses`), may carry `timer_seconds`, and
  may carry a `thermometer` check with an endpoint temperature and a pinned source
  (`usda-fsis: ground beef 160 F`). Food-safety verdicts stay grounded in pinned
  sources, consistent with #126 — the camera never issues a verdict.
- **Claims** (`vegetarian`, `vegan`, `gluten_free`, `dairy_free`) are `boolean | null`.
  Null means unknown, and allergen/allRestriction checks treat null as "fails" —
  the same fail-closed rule as the allergen engine. The sample demonstrates null
  (`gluten_free: null` on the beef stir-fry — soy sauce brand unknown).
- **Nutrition** is per-serving with a required `coverage` enum: `computed` (every
  weighed line has a per-100 g row), `partial` (some lines lack values), `estimated`
  (values supplied outside the catalog) — plus a free-text `basis` naming which lines
  carry what. Sodium is milligrams; the bundled catalog stores grams and the compiler
  converts.
- **Rights**: `status: original | licensed | attribution_only` with `evidence`. URL
  attribution alone is not licence evidence (#43 audit); `attribution_only` rows are
  display-only and excluded from sharing.
- **`required: false`** marks optional lines (garnish), `assumed_staple` marks
  pantry-stable items the fridge need not contain for a suggestion to surface.

`contracts/examples/bundle-v2.sample.json` is a 6-recipe, 20-ingredient working
example covering every quantity kind, two thermometer checks (egg dishes, ground
beef — both FSIS-pinned), all three nutrition coverage levels, a revision bump, optional/staple lines, and a substitution-friendly
pair (cilantro → lemon) used by the taste events.

## 3. Taste-signal events v1

`contracts/taste-events-v1.schema.json` — the envelope the recipe system emits to
on-device taste learning: `cook_started / cook_completed / cook_abandoned /
recipe_rated / suggestion_accepted / suggestion_dismissed`, bound to
`recipe_catalog_id` + `recipe_revision`, an opaque `household_id`, and a `source`.
`recipe_rated` carries `rating`; `suggestion_dismissed` carries a closed-set
`dismiss_reason`; `cook_completed` may carry `scaled_servings` and structured
`substitutions` (canonical keys, e.g. cilantro → lemon).

Events stay on the phone and are consumed by LearningService replay (#53). The
profile, feature contributions, and decay semantics are owned by the taste-residual-v1
spec (PR #146) — this contract fixes only the event vocabulary, so bundle revisions
and session records can't drift from what the learner replays.

## 4. Machine checks

`python3 contracts/check.py` (needs `jsonschema`, see `contracts/requirements.txt`):

- all three schemas are valid JSON Schema 2020-12;
- all three examples validate against their schemas;
- cross-checks: bundle keys/ids unique and referenced, `uses` indexes in range,
  identity map covers legacy ids 1–50 exactly with names matching `data.json`,
  every non-null fdc_id exists in the bundled catalog, taste events reference only
  sample-bundle recipes and canonical keys, and the sample covers all six event
  types.

Current state: all green (50 identity entries, 6 recipes, 6 events). The identity
map in `examples/` is generated by the rules in §1 — the generator is scripted and
the run is recorded in the PR body; check.py re-validates the committed artifact
against the live catalog.

## 5. Decisions and alternatives

- **Canonical key as join key, not integer ids.** Alternative: renumber the catalog
  to include legacy ids 1–50. Rejected — it collides with FDC id space and repeats
  the original bug.
- **Three identity statuses, not two.** A hard resolved/unresolved split would force
  guessing on entries like `chickpea` (single candidate, unconfirmed form). `proposed`
  keeps the candidate auditable without asserting it.
- **Nutrition `coverage` + `basis` instead of hiding partial data.** Hiding it
  misleads; refusing to ship partial values empties the catalog. The band stays
  honest per recipe.
- **Claims fail-closed via null.** Alternative: infer `gluten_free` from ingredients.
  Rejected — inference belongs in the allergen engine where it can be audited, not
  in shipped data.
- **Sample bundle of 6, not 166.** The contract layer needs to demonstrate every
  shape, not ship volume; #144 already handles expansion of the legacy corpus.

## 6. Not covered here

Bundle compilation tooling (`RecipesCompiler`), the planner's substitution ranking,
full-FDC import for the 27 unresolved identities, and migration of the 166 legacy
rows into v2 revisions. Each is follow-up work with this schema as its input.
