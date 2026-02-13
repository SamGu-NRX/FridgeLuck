# FridgeLuck UI/UX Audit and Redesign Spec

Date: 2026-02-13
Scope: Ingredient-centric flow redesign with shared visual system and reusable picker/search UX.

## 1) Before/After UX Map

### Before
- Home: functional launch page with limited hierarchy and weak action emphasis.
- Scan: capture/process/recover states were implicit and error recovery path felt abrupt.
- Ingredient Review: strong logic, dense hierarchy, manual add/correction picker duplicated search behavior.
- Ingredient Detail: nutrition present but less cohesive card rhythm and weak alias surfacing.
- Results + Recipe Detail: usable but visual language did not align tightly with scan/review surfaces.
- Onboarding allergens: separate picker behavior and inconsistent search UX.

### After
- Home: editorial hero, stronger CTA hierarchy, concise profile/readiness status.
- Scan: explicit staged experience (Capture, Analyze, Review-ready/Error) with clear recovery branches.
- Ingredient Review: summary-first structure, confidence health indicator, quick bulk actions, shared picker for manual add/correction.
- Ingredient Detail: description-first hero, macro trio + secondary nutrients, alias chips.
- Results: context summary, stronger quick pick, richer card metadata.
- Recipe Detail: consistent card rhythm, step cards, sticky bottom completion CTA.
- Onboarding allergens: shared `IngredientPickerView` for consistent alias-backed search behavior.

## 2) Core Findings and Fixes

1. Search behavior was fragmented across screens.
- Fix: consolidated into `IngredientPickerView` using repository-backed `search(query:limit:)`.

2. Uncertain detection UX required too much cognitive load.
- Fix: explicit review sections + candidate chips + one-tap correction paths + batch actions.

3. Empty/loading/error states were not narratively aligned.
- Fix: reusable `FLEmptyState`, richer loading cards, stronger retry/manual fallback wording.

4. Visual language lacked a shared system.
- Fix: `AppTheme`, `AppComponents`, `AppMotion` and migration of target screens to those primitives.

## 3) Design Tokens and Component Rules

### Theme tokens (`AppTheme`)
- Color roles: accent, background, surface, muted surface, primary/secondary text, status colors.
- Spacing scale: `xxs`, `xs`, `sm`, `md`, `lg`, `xl`.
- Radius scale: `sm`, `md`, `lg`, `xl`.
- Elevation: one consistent soft shadow profile.

### Shared components (`AppComponents`)
- `FLCard`: default container for elevated content blocks.
- `FLSectionHeader`: section title + optional subtitle + icon.
- `FLPrimaryButton`/`FLSecondaryButton`: consistent action hierarchy.
- `FLStatusPill`: compact status signal for quality/progress.
- `FLEmptyState`: standardized no-content/error guidance.

### Usage rules
1. Prefer `FLCard` + `FLSectionHeader` over ad-hoc stack/stroke styles.
2. Keep one primary CTA per major section.
3. Use status pills sparingly for confidence or completion only.
4. Keep section spacing from `AppTheme.Space`; avoid per-view magic numbers unless necessary.

## 4) Accessibility and Performance Guardrails

1. Ensure primary actions remain visible at large Dynamic Type sizes.
2. Avoid color-only status signals; pair with icon/text.
3. Keep tap targets at or above 44pt vertical comfort.
4. Keep search operations repository-backed and debounced to avoid main-thread stalls.
5. Restrict heavy transitions to high-value navigation moments.

## 5) Known UX Debt (Deferred)

1. Ingredient sprite artwork is still SF Symbol based; future custom icon packs can slot into `sprite_key`/`sprite_group` resolution.
2. Recipe filtering controls (time, dietary tags) remain lightweight and can be expanded later.
3. Progressive onboarding personalization (adaptive prompts by behavior) is not in this pass.

## 6) Future Art-Asset Slots (No Architecture Change Needed)

1. Ingredient list/result card thumbnail slot driven by `sprite_key`.
2. Category-level icon fallback slot driven by `sprite_group`.
3. Optional scan hero illustration slot in capture stage card.

## 7) Files Updated in This Pass

- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/UI/AppTheme.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/UI/AppComponents.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/UI/AppMotion.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/ContentView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Scan/ScanView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Ingredients/IngredientPickerView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Ingredients/IngredientReviewView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Ingredients/IngredientDetailSheet.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Results/RecipeResultsView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Recipe/RecipeDetailView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Features/Onboarding/OnboardingView.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Data/Repository/IngredientRepository.swift`
- `/Users/samgu/Programming Projects/fridgeluck/FridgeLuck.swiftpm/Data/Repository/RecipeRepository.swift`
