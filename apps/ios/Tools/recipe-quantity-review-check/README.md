# recipe-quantity-review-check

Offline Linux verification harness for the read-only recipe amount review
(`RecipeQuantityReviewView` / `RecipeQuantityReviewSession`).

Run:

```bash
./link-sources.sh && swift test
```

## What it compiles

The `RecipeQuantityReviewCheck` target contains **symlinks** into the app's existing
sources — nothing is forked:

- `Domain/Models`: `Recipe.swift`, `Ingredient.swift`, `IngredientSwap.swift`,
  `HealthProfile.swift`, `UserProgress.swift`
- `Platform/Persistence`: `RecipeRepository.swift`, `RecipeScoring.swift`,
  `NutritionService.swift`, `SubstitutionService.swift`, `HealthScoringService.swift`,
  `PersonalizationService.swift`, `Migrations.swift`
- `FeatureLogic/RecipeQuantityReview/`: the review models, calculator, and session

All of these are `Foundation` + `GRDB` only, which is what makes them buildable and
runnable on Linux. The SwiftUI layer (views, `AppDependencies`) is not part of the
closure and is verified by the iOS build/CI instead.

## What the tests verify

- **Calculator** — the serving factor `selected / recipeServings` is applied exactly
  once, the substitute's ratio exactly once on top of it, calories scale the stored
  energy value (never a 4/4/9 reconstruction), fractional servings work, and required
  and optional totals are computed separately with unavailable nutrition refusing a
  total instead of zero-filling it.
- **Validation** — a single recipe identity is established before the serving
  denominator is fetched: nil IDs, empty rows, foreign rows, duplicate ingredients,
  non-finite or negative grams, unusable ratios, and zero/negative denominators all
  refuse the load.
- **Session** — end-to-end `load` against a real migrated GRDB database seeded with
  synthetic rows (real `RecipeRepository` / `NutritionService`), cancellation between
  read steps so a stale load never returns a snapshot, read-failure surfacing, and
  reference reads degrading to nil rather than zero.
- **No writes** — the review flow runs against an on-disk migrated database and a
  full content dump of every table is compared byte-for-byte before and after,
  across every serving option. The review is read-only by construction; this proves
  it.

## Mirrored adapter

The production reader (`AppRecipeQuantityReviewReader`, app target) maps the same
three synchronous interfaces onto the FeatureLogic session. That file cannot be
imported here (the app target is an Xcode framework), so the tests carry an
equivalent `ReaderAdapter` with the identical mapping over the real services. If the
production reader's mapping changes, this mirror and it must change together — the
PR notes call this out.
