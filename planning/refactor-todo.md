# FridgeLuck Refactor To-Do (Active)

## Operating Rules
- Preserve current runtime behavior (zero intentional feature changes).
- Prefer move/extract/refine over logic rewrites.
- Run full `xcodebuild test` after each major batch.
- Keep this checklist current as the source of truth.

## Phase 1: Safety + Baseline
- [x] Confirm current branch builds/tests before further edits.
- [x] Confirm folder taxonomy migration compiles after path moves.
- [x] Capture current hotspot LOC snapshot for decomposition targeting.
- [x] Validate docs/guidance via Context7 for SwiftUI decomposition + SwiftPM config decisions.
- [ ] Add characterization tests for recipe flow state transitions (substitutions/toggle completion) before any future behavior edits.
  Blocked in current `.iOSApplication` test wiring: `@testable import FridgeLuck` requires a `FridgeLuck` dependency that cannot be declared as a normal target dependency, while `@testable import AppModule` fails module resolution in `AppModuleTests`.
- [x] Evaluate adopting `swift-testing` for new test coverage while keeping existing XCTest tests stable.
  Context7-confirmed: Swift Testing can coexist with XCTest incrementally. Decision: defer adoption until test-import wiring blocker above is resolved.
- [x] Validate `.iOSApplication` multi-target feasibility in this playground format before attempting target extraction in a future phase.
  Verified on 2026-03-03 by temporarily adding `ArchitectureProbe` target + `AppModule` dependency and running full `xcodebuild test` successfully.

## Phase 2: Taxonomy + Naming Structure
- [x] Move root app wiring into `App/` (`MyApp`, `ContentView`, `AppDependencies`).
- [x] Move domain models into `Domain/Models`.
- [x] Move persistence infra into `Platform/Persistence/*`.
- [x] Move recognition/intelligence engines into `Capability/Core/*`.
- [x] Move reusable UI primitives into `DesignSystem/`.
- [x] Move screens into `Feature/*` with feature-first grouping.
- [x] Keep naming convention as feature-prefixed type names (no namespace-wrapper enums).
- [x] Add shared tutorial key registry (`Feature/Shared/TutorialStorageKeys.swift`).

## Phase 3: Hotspot Decomposition (Primary)
- [x] `Feature/Ingredients/IngredientReviewView.swift`: extract section views.
- [x] `Feature/Ingredients/IngredientReviewView.swift`: extract supporting chip/photo/button views.
- [x] `Feature/Home/HomeDashboardView.swift`: extract tutorial sections.
- [x] `Feature/Home/HomeDashboardView.swift`: extract graduated dashboard sections.
- [x] `Feature/Home/HomeDashboardView.swift`: extract analytics/footer sections.
- [x] `Feature/Scan/ScanView.swift`: extract stage sections.
- [x] `Feature/Onboarding/OnboardingView.swift`: extract step/header/footer sections.
- [x] `Feature/Demo/DemoModeView.swift`: extract section + overlay files.
- [x] `Feature/Recipe/RecipePreviewDrawer.swift`: extract section components.

## Phase 4: Boundary Cleanup + Composition Hygiene
- [x] Move direct recipe count SQL out of feature ViewModel into repository API.
- [x] Keep feature files orchestration-focused with section composition.
- [x] Reduce direct full-container coupling (`AppDependencies`) where low-risk scoped deps are obvious.
- [x] Add scoped dependency structs for high-traffic screens:
- [x] `ScanView.Dependencies` (vision, scan store, ingredient repo, learning).
- [x] `IngredientReviewView.Dependencies` (repos, nutrition, recommendation engine).
- [x] `CookingGuideView.Dependencies` (recipe repo, substitution service).
- [x] `CookingCelebrationView.Dependencies` (user repo, image storage, personalization).
- [x] Keep temporary adapter initializers so existing call sites continue to compile.
- [x] Add future-facing `AgentConversationProviding` seam (scaffold only, no runtime online logic).

## Phase 5: Tooling / Warnings / Guardrails
- [x] Update `Package.swift` source roots to match new folder layout.
- [x] Investigate duplicate `Assets.xcassets` warning with clean build logs (confirmed emitted by `.iOSApplication` generated project pipeline).
- [ ] Resolve duplicate `Assets.xcassets` warning without breaking `AppIcon` lookup (currently blocked by SwiftPM Playground project generation behavior).
- [x] Add lightweight size/cohesion audit script (guideline-only, not hard LOC enforcement).
- [x] Document folder + naming template for future contributors in `planning/`.
- [ ] Run dead-code scan (`periphery` or equivalent) and review removals separately from structural refactor.
  `periphery` is not installed in this environment (`which periphery` returns not found); pick install path or approved alternative scanner first.

## Phase 6: Regression Gates
- [x] Full regression test run after ingredient/home extraction batch.
- [x] Full regression test run after this current batch.
- [x] Full regression test run after `Feature/Results/RecipeResultsView` split.
- [x] Full regression test run after `Feature/Home/SpotlightTutorialOverlay` split.
- [x] Full regression test run after `DesignSystem/AppComponents` split.
- [x] Full regression test run after `Feature/Recipe/CookingCelebrationView` split.
- [x] Full regression test run after `Feature/Recipe/CookingGuideView` split.
- [x] Full regression test run after `CookingGuide`/`CookingCelebration` scoped dependency seams.
- [x] Full regression test run after `ScanView`/`IngredientReviewView` scoped dependency seams.
- [x] Full regression test run after `RecipeRepository` cohesion split (`RecipeScoring.swift` extraction).
- [x] Full regression test run after `BundledDataLoader` cohesion split (`USDACatalog` + `RecipeHydration` helpers).
- [x] Full regression test run after temporary multi-target feasibility probe injection + rollback.
- [ ] Manual critical path verification pass:
- [ ] Manual path: onboarding gate and profile save.
- [ ] Manual path: scan -> review -> results flow.
- [ ] Manual path: demo scenario flow.
- [ ] Manual path: recipe cook + journal path.
- [ ] Manual path: dashboard load + reset path.

## Secondary Decomposition Backlog (Cohesion-Driven)
- [x] `Feature/Home/SpotlightTutorialOverlay.swift`
- [x] `DesignSystem/AppComponents.swift` -> split into `DesignSystem/Components/*`.
- [x] `Feature/Recipe/CookingCelebrationView.swift` -> split into orchestration + sections + picker.
- [x] `Feature/Recipe/CookingGuideView.swift` -> split into orchestration + section/chrome components.
- [x] `Feature/Results/RecipeResultsView.swift`
- [x] `Platform/Persistence/Repository/RecipeRepository.swift` -> split scoring models/heuristics into `RecipeScoring.swift`.
- [x] `Platform/Persistence/Bundle/BundledDataLoader.swift` -> split USDA import + recipe hydration helpers into companion files.

## Detailed Remaining Steps (Execution Order)
- [x] Step 1: split `Feature/Recipe/CookingCelebrationView.swift` sections into companion file(s).
- [x] Step 2: move `MealPhotoPicker` into `Feature/Recipe/MealPhotoPicker.swift`.
- [x] Step 3: keep `CookingCelebrationView` focused on orchestration/state transitions.
- [x] Step 4: split `Feature/Recipe/CookingGuideView.swift` into page/row/navigation section files.
- [x] Step 5: verify substitutions and completion toggles still behave exactly the same.
  Verified by preserving exact toggle semantics in `CookingGuideStateTransitions` and keeping all call sites unchanged except extraction.
- [x] Step 6: re-run full `xcodebuild test`.
- [x] Step 7: inspect duplicate `Assets.xcassets` warning with package-generated project settings.
- [ ] Step 8: implement warning fix only if `AppIcon` asset resolution remains intact (currently blocked by `.iOSApplication` generation behavior).
- [x] Step 9: rerun cohesion audit and refresh hotspot snapshot.
- [ ] Step 10: complete manual critical-path verification checklist.
- [x] Step 11: move `ScanView.Dependencies` and `IngredientReviewView.Dependencies` into dedicated files to trim root-screen LOC without changing behavior.
- [x] Step 12: split `BundledDataLoader` helpers into companion files to separate USDA import logic from recipe hydration logic.
- [x] Step 13: validate `.iOSApplication` multi-target feasibility in-repo via temporary `ArchitectureProbe` target + successful `xcodebuild test`, then rollback probe artifacts.
- [ ] Step 14: unblock characterization tests by deciding on one strategy:
  Option A: introduce a small pure-logic target for transition helpers.
  Option B: keep manual verification gate until future target extraction.

## Current Hotspot LOC Snapshot
- `Feature/Ingredients/IngredientReviewView.swift` -> ~618
- `Feature/Home/HomeDashboardView.swift` -> ~372
- `Feature/Scan/ScanView.swift` -> ~525
- `Feature/Onboarding/OnboardingView.swift` -> ~372
- `Feature/Demo/DemoModeView.swift` -> ~314
- `Feature/Recipe/RecipePreviewDrawer.swift` -> ~207
- `Feature/Results/RecipeResultsView.swift` -> ~197
- `Feature/Recipe/CookingCelebrationView.swift` -> ~255
- `Feature/Recipe/CookingGuideView.swift` -> ~248
- `Feature/Recipe/CookingGuideSections.swift` -> ~311
- `Feature/Recipe/CookingCelebrationSections.swift` -> ~285
- `Feature/Profile/DashboardView.swift` -> ~458
- `Platform/Persistence/Repository/RecipeRepository.swift` -> ~369
- `Platform/Persistence/Repository/RecipeScoring.swift` -> ~123
- `Platform/Persistence/Bundle/BundledDataLoader.swift` -> ~324
- `Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift` -> ~147
- `Platform/Persistence/Bundle/BundledDataLoaderRecipeHydration.swift` -> ~165

## Validation Notes (2026-03-03)
- Context7 + local experiment confirms Swift Testing can coexist with XCTest, but current test module wiring in `.iOSApplication` prevents direct `@testable` coverage of app internals.
- Multi-target feasibility is validated for this package format with real compile/test evidence (temporary `ArchitectureProbe` target dependency).
- Duplicate `Assets.xcassets` warning remains reproducible and unresolved without breaking `AppIcon` resolution.
