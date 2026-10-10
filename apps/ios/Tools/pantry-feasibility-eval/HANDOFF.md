# Handoff — live production replay arm (pantry-feasibility eval)

## What was added

The pantry-feasibility evaluation (draft PR #54) previously compared production's
makeability predicate only through a **transcription** — a Swift re-implementation
of `RecipeRepository.findMakeable` / `findNearMatch` checked against a Python
transcription on all 863,200 (state, recipe) pairs. Reviewer feedback asked for a
**live arm**: the actual production code running on real migrated databases.

`production/` is a new SwiftPM package that links the real app sources:

- Real `DatabaseMigrations.migrate` (in-memory database, one per corpus state).
- Real `RecipeRepository`, `NutritionService`, `HealthScoringService`,
  `PersonalizationService`, and the domain models (`Recipe`, `Ingredient`,
  `HealthProfile`, `Inventory`, `UserProgress`, `DishTemplate`,
  `AllergenGroupMembership`, `IngredientSwap`), copied verbatim by
  `Scripts/refresh.sh` from `apps/ios/FridgeLuck/` into `Real/`
  (gitignored — refreshed at build, never committed stale).
- Vendored GRDB.swift from `apps/ios/Vendor/GRDB.swift`.

Seeding mirrors photo-intake persistence: core ingredients (IDs 1–50, macro
columns zeroed — macros do not participate in makeability), all 166 bundled
recipes with required/optional `recipe_ingredients` rows, one `HealthProfile`
row (diet persisted as dietary-restriction IDs, allergens as JSON arrays — the
production representation), and pantry lots where unknown amounts land as
estimate lots (`quantity_is_estimate`, matching the v16 migration semantics).

The runner calls the **actual** `findMakeable(with:profile:limit:)` and
`findNearMatch(with:profile:maxMissingRequired:limit:)` and emits the resulting
recipe-ID sets per state to `runs/production_replay.jsonl`.

## Verified results

`verify_production.py runs` compares the live result sets against the Python
transcription for all 5,200 states:

```json
{"production_live_states": 5200, "makeable_set_agreement": 5200,
 "near_match_set_agreement": 5200, "agreement_rate": 1.0, "mismatches": []}
```

- Live arm (real sources) vs transcription: **identical on all 5,200 states**,
  for both the makeable set and the near-match set.
- `run_eval.py` now labels the three arms in `runs/report.json` and folds in the
  live verification. Per-pair metrics re-derived from a fresh Swift replay
  reproduced the committed numbers exactly: 25,524 production-makeable pairs,
  11,846 false-complete (46.4%), 0 false-blocks, oracle-feasible recall 1.0,
  planted-family false-complete rate 64.2%.
- `verify_replay.py` re-run after regeneration: membership sync 50 rows
  identical; 863,200 rows identical across Python and Swift.

Conclusion: the 46.4% false-complete finding is **not a transcription artifact** —
the production code itself over-promises on exactly those pairs.

## How to reproduce

```sh
# Swift 6.1.2 toolchain + libsqlite3-dev required on Linux
cd apps/ios/Tools/pantry-feasibility-eval
python3 check_states.py && python3 -m pytest -q
python3 verify_replay.py
cd production && bash Scripts/refresh.sh
swift build -Xswiftc -DSQLITE_DISABLE_SNAPSHOT
.build/debug/PantryFeasibilityProduction --corpus-dir ../runs --output ../runs/production_replay.jsonl
cd .. && python3 verify_production.py runs && python3 run_eval.py
```

The live replay takes ~19 minutes (5,200 states × migrate + seed + query).

## What was not checked

- **Xcode / Apple toolchains:** no Xcode in this environment. The production
  package compiles with Swift 6.1.2 on Linux (`-DSQLITE_DISABLE_SNAPSHOT` is
  needed because Ubuntu's libsqlite3 lacks the WAL-snapshot symbols the vendored
  GRDB compiles for); the hosted macOS CI build of the iOS app target is the
  check for Apple-toolchain behavior.
- The live replay ran on Linux with Swift 6.1.2 only. GRDB SQLite behavior
  differences between platforms are considered negligible for these queries but
  were not measured on a Mac.
- UI/UX or end-user flows were not exercised; this is a headless data check.

## Assumptions

- Macro columns of core ingredients are zeroed — makeability depends on
  ingredient membership, quantities, diet tags, and allergen exclusions, not
  macros; if production later gates on nutrition, the corpus needs re-seeding.
- `servings` is stored as 2 and `source` as `'bundled'`; neither participates in
  the predicates under test.
- Diet values map onto `HealthGoal`/dietary-restriction IDs exactly as the app's
  settings persistence does (restriction ID list, not a raw string column).
- Estimated lots are stored with `quantity_is_estimate = 1` and unknown grams as
  0, mirroring photo-intake; the oracle treats them as presence-only.

## Also in this diff

- Test-only fixes for CI failures this PR's run exposed; all are pre-existing
  debt on the base branch (`obv/fridgeluck-001`), whose own latest CI run fails
  at compile before reaching them:
  - `AllergenExclusionPolicyTests.swift`: migration calls run on the
    `DatabaseQueue` outside `db.write` blocks (the inherited code passed the
    write closure's `Database` to `DatabaseMigrations.migrate`, which requires a
    `DatabaseQueue` — the same compile error red on the base branch's CI).
  - `MigrationUpgradeTests.swift`: the expected newest-three migration list was
    not updated when `v19_explicit_allergen_groups` landed (commit c18ece18);
    it now expects v17-v19.
  - `OnboardingGatePolicyTests.swift`: the hand-rolled `health_profile` fixture
    lacked the v19 columns `allergen_selected_groups` and
    `allergen_preferences_version`; added with the production defaults.
  The iOS test changes were compiled and run only by the hosted macOS CI — no
  Xcode in this environment.
