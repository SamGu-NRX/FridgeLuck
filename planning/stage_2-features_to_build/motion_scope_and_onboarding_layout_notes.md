# FridgeLuck Motion Scope + Onboarding Layout Notes

## Core Principles
1. Motion must communicate state change, not decorate every update.
2. Prefer fast ease-out curves (`<= 240ms`) for perceived responsiveness.
3. Use blur only when transitioning between visually disjoint states; never as a default text/count change effect.
4. Keep bidirectional parity: every forward step transition should have an equally clear reverse transition.
5. Keep structural rhythm fixed across steps: consistent header height, progress bar height, footer height, and button heights.

## Animation Scope Rules
1. High-priority motion targets:
   - Step-to-step onboarding transitions.
   - Press feedback on interactive controls.
   - Meaningful insert/remove transitions for dynamic sections.
2. Low-priority motion targets:
   - Counter text changes (e.g. `Find Recipes (3) -> (4)`): no blur, no heavy transition.
   - Repeated list interactions: avoid layered effects that slow perceived flow.
3. Reduction rule:
   - If motion does not improve comprehension, remove it.

## Onboarding Layout Rules
1. Header is fixed-height across all steps to prevent vertical jumping.
2. Footer/action bar is fixed-height across all steps.
3. Primary/secondary action controls share a common minimum tap height.
4. Common-allergen chips use fixed heights so both grid columns align.

## Data Source Rule (Allergen Selection)
1. All allergen selection surfaces read ingredients from app SQLite via `IngredientRepository`.
2. USDA-curated ingredient content should enter UI through SQLite-loaded records, not ad-hoc in-memory lists.
