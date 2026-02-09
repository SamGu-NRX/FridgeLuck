# FridgeLuck Stage 2 Feature Build Plan

Date: 2026-02-08  
Source of truth reviewed:
- `planning/stage_1-technical/context.md`
- `planning/stage_1-technical/plan.md`

This document is a feature-completeness audit and build backlog.  
Goal: move from "builds and launches" to "Stage 1 plan is functionally delivered."

## Audit Summary

- App compiles in Xcode (per your note), launches, and has a working baseline flow.
- Significant portions of the Stage 1 planned functionality are still partial or missing.
- Core architecture exists (GRDB, schema, scan flow, recommendations), but key user-facing and product-defining features are not fully wired.

## What Is Already Implemented

- SQLite + GRDB persistence and migration scaffolding:
  - `FridgeLuck.swiftpm/Data/Database/Migrations.swift`
  - `FridgeLuck.swiftpm/Data/Database/AppDatabase.swift`
- Bundled data bootstrap pipeline:
  - `FridgeLuck.swiftpm/Data/Bundle/BundledDataLoader.swift`
- Two-pass Vision pipeline (classification + OCR):
  - `FridgeLuck.swiftpm/Recognition/VisionService.swift`
- Confidence bucketing (high/medium/low):
  - `FridgeLuck.swiftpm/Recognition/ConfidenceRouter.swift`
- Recipe matching, macros, health score, personalization:
  - `FridgeLuck.swiftpm/Data/Repository/RecipeRepository.swift`
  - `FridgeLuck.swiftpm/Services/NutritionService.swift`
  - `FridgeLuck.swiftpm/Services/HealthScoringService.swift`
  - `FridgeLuck.swiftpm/Services/PersonalizationService.swift`
- Primary screens exist:
  - Home, Scan, Ingredient review, Results, Recipe detail

## High-Impact Gaps (Must Build)

These are the gaps most likely causing "app starts but functionality does not fully work as planned."

### P0-1: Onboarding + health profile flow is missing

Current state:
- App always enters `ContentView` after DB setup (`FridgeLuck.swiftpm/MyApp.swift`).
- `UserDataRepository.hasCompletedOnboarding()` exists, but there is no onboarding feature/screen.
- `Features/Onboarding` does not exist.

Why this matters:
- Stage 1 plan requires first-launch health goal, restrictions, allergens, calorie target.
- Without this, health scoring is effectively default-only and not user-personalized.

Build tasks:
1. Create `Features/Onboarding` flow with goal, restrictions, allergens, calories.
2. Save into `health_profile` via `UserDataRepository.saveHealthProfile`.
3. Gate entry so first launch routes to onboarding before main flow.
4. Add edit profile entry point from app UI.

Acceptance:
- Fresh install forces onboarding.
- Returning users skip onboarding.
- Changing profile measurably affects recipe ranking and health labels.

### P0-2: Demo Mode does not use bundled demo image pipeline

Current state:
- Demo mode is hardcoded detections in `ContentView` (`demoDetections`) and bypasses scan pipeline.
- No demo image resource exists. Only `Resources/data.json` is present.

Why this matters:
- Stage 1 design expects deterministic bundled image path and same recognition/review flow.

Build tasks:
1. Add bundled `demo_ingredients.jpg`.
2. Implement "Run demo scan" path that uses real scan pipeline or deterministic fixture load from image metadata.
3. Keep fallback deterministic if Vision is unavailable.

Acceptance:
- Demo mode works fully offline and does not rely on hardcoded ingredient arrays in view code.

### P0-3: Confidence UX is incomplete (no real disambiguation workflow)

Current state:
- Medium-confidence items are displayed as chips but there is no "X or Y" prompt with alternatives.
- No top-3 alternative selection UX.
- No correction capture from review actions.

Why this matters:
- Confidence-based interaction is a core differentiator in both planning docs.

Build tasks:
1. Extend detection payload to carry alternatives (top-N candidates).
2. Build medium-confidence confirmation card with explicit choices.
3. Add manual correction path that records correction pairs.
4. Wire correction commits to `LearningService.recordCorrection(...)`.

Acceptance:
- Medium-confidence labels provide alternatives.
- User correction persists and influences future scans.

### P0-4: Continual learning service is not connected end-to-end

Current state:
- `LearningService` has full correction APIs.
- `recordCorrection(...)` and `suggestedCorrection(...)` are never called from UI.

Why this matters:
- Planned continual learning loop is currently mostly dormant.

Build tasks:
1. On user correction, call `recordCorrection`.
2. For medium confidence, preselect/use `suggestedCorrection`.
3. Add lightweight telemetry counters (local only) for correction hit rate.

Acceptance:
- Repeating same correction improves subsequent classification behavior.

### P0-5: Ingredient nutrition cards (tap-to-learn) are missing

Current state:
- Nutrition exists at recipe level in `RecipeDetailView`.
- No ingredient-level detail view from detection/results flow.
- `pairs_with` and cultural usage content are not modeled in current data.

Why this matters:
- Stage 1 requires ingredient cards for calories/macros + storage tips + pairing notes.

Build tasks:
1. Add ingredient detail sheet view (from ingredient chips/list items).
2. Display calories/macros per 100g + typical unit + storage tip.
3. Expand ingredient data schema for optional educational fields (`pairs_with`, notes).

Acceptance:
- Tapping an ingredient anywhere relevant opens its nutrition card.

### P0-6: Data scale is far below planned scope

Current state:
- `Resources/data.json` currently has 25 recipes and 50 ingredients.
- Stage 1 plan target is much larger (at least meaningful breadth, plan calls for 1000+ in extended architecture).

Why this matters:
- Low corpus causes weak match quality and can make app feel non-functional for real fridges.

Build tasks:
1. Expand data to at least Stage-2 target set (suggested: 200+ recipes, 150+ ingredients minimum).
2. Validate ingredient ID integrity and macro sanity checks.
3. Add data QA script for duplicate titles, missing references, outlier macros.

Acceptance:
- Recipe results remain useful for varied ingredient sets.

### P0-7: Foundation Models integration is currently stubbed/commented

Current state:
- AI generator code path is commented and always falls back.
- Platform target is iOS 18 (`Package.swift`), while plan path for Foundation Models targets iOS 26+.

Why this matters:
- Planned optional AI enhancement path is not operational.

Build tasks:
1. Decide Stage 2 target strategy:
   - Option A: keep iOS 18 baseline and explicitly defer Foundation Models.
   - Option B: move to iOS 26 and ship real Foundation Models integration behind availability checks.
2. If Option B: uncomment and integrate generator + normalized ingredient enhancement UI.

Acceptance:
- Decision is explicit and reflected in architecture docs and code.

### P0-8: Recommendation engine object exists but is unused in UI flow

Current state:
- `RecommendationEngine` has orchestration logic and AI generation API.
- Current views call repository/services directly and bypass this orchestrator.

Why this matters:
- Logic is split across UI and services, making feature growth and testing harder.

Build tasks:
1. Either adopt `RecommendationEngine` as single orchestration surface or remove it.
2. Move async loading/state/error handling for recommendations into one model.

Acceptance:
- One canonical recommendations execution path in production flow.

## Important P1 Gaps

### P1-1: OCR-based packaged calories parsing not implemented

Current state:
- OCR exists, but there is no nutrition-label parser for calories/serving-size extraction.

Build tasks:
1. Add parser for common label patterns (Calories, Serving Size, Servings per container).
2. Show parsed values as override/source for packaged foods.
3. Add confidence + fallback messaging when parse fails.

### P1-2: Prepared dish estimation workflow not implemented

Current state:
- No dish-template fallback with range estimates ("small/normal/large").

Build tasks:
1. Add dish template table.
2. Add dish estimate UI with size selector.
3. Present range output with approximation marker.

### P1-3: Permission declaration and cross-device safety hardening

Current state:
- Camera/photo picker is used, but explicit permission metadata hardening is not visible in this package manifest setup.

Build tasks:
1. Verify camera/photo descriptions are set in app configuration for build/distribution mode.
2. Test deny-permission behavior paths and copy.

### P1-4: Demo/asset/UI polish from Stage 1 design language is missing

Current state:
- No pixel spritesheet, no pin-card component, no scan animation asset path.

Build tasks:
1. Add visual component set (`PinCard`, scan animation, spritesheet support) without breaking performance.
2. Ensure mobile + iPad layout quality.

### P1-5: Packaging/offline dependency hardening

Current state:
- Project uses remote SwiftPM dependency for GRDB in `Package.swift`.
- Stage 1 constraints emphasize robust offline judging and no network dependence during the judging experience.

Build tasks:
1. Confirm judge/runtime path is fully offline-safe with dependency already resolved.
2. If needed, vendor/pin dependency strategy for deterministic offline open/build.
3. Add pre-submission verification checklist item for clean-machine offline launch.

## P2 (Nice to Have / Time-Permitting)

1. Quests + badges UI beyond DB tables.
2. Progress dashboard for streaks, meals cooked, and milestone badges.
3. Community/future-direction mock screens (non-core).

## Execution Order (Recommended)

1. P0-1 Onboarding and profile gating.
2. P0-3 + P0-4 Confidence disambiguation and learning loop.
3. P0-2 Demo image path and deterministic offline demo flow.
4. P0-5 Ingredient nutrition cards.
5. P0-6 Data expansion and QA.
6. P0-8 Recommendation orchestration cleanup.
7. P1/P2 items as time allows.

## Definition of Done for Stage 2

Stage 2 is complete when:
- Core loop works end-to-end with real scan/demo inputs and correction learning.
- Health onboarding is functional and affects recommendations.
- Ingredient-level nutrition cards are available in the scan-to-results path.
- Data coverage is broad enough to avoid frequent "no useful match" outcomes.
- Feature ownership is centralized (orchestrated) and testable.

## Deep Technical Workstreams

### Workstream A: Recognition Pipeline (Offline)

Clarification:
- OCR is implemented today (`VNRecognizeTextRequest` exists in `VisionService`), but it is not production-complete and is weakly integrated.

Build tasks:
1. Pipeline contract
   - Define `ScanInput` (`image`, `orientation`, `source`) and `ScanDiagnostics` (`passErrors`, `rawTopLabels`, `ocrCandidates`).
   - Return structured outputs for debugging and threshold tuning.
2. Pass execution
   - Keep two-pass flow: classification + OCR.
   - Add optional crop strategy (center + quadrants) for wide-fridge photos.
3. Label normalization
   - Normalize punctuation, Unicode variants, and package text tokenization before lexicon matching.
   - Move lexicon mappings into a versioned DB table (`label_aliases`) with migration support.
4. OCR optimization
   - Configure language list and custom words using ingredient names.
   - Use candidate confidence + text height filters; do not rely on first candidate only.
5. Deterministic fallbacks
   - If both passes fail, return actionable failure state, not silent empty success.

Acceptance:
- Repeated scans of same image are stable.
- Diagnostics make false positives/negatives debuggable.
- OCR materially improves packaged-item recall without exploding false positives.

### Workstream B: Confidence Semantics and Calibration

Apple API facts to anchor decisions:
- `VNObservation.confidence` is in `[0,1]` under most circumstances.
- For `VNCoreMLRequest`, Vision can forward model confidences as-is (not guaranteed calibrated probabilities).
- High confidence does not guarantee correctness; thresholds must be empirically tuned.

Build tasks:
1. Define confidence policy
   - Confidence is a ranking signal, not truth probability.
   - Keep UX buckets (`auto`, `confirm`, `possible`) but calibrate with measured precision/recall.
2. Build an evaluation set
   - 300+ labeled photos (close-up and wide-shot), with ground-truth ingredient sets.
   - Include packaged foods, leftovers, and difficult lighting.
3. Threshold calibration tooling
   - Script to compute precision/recall/F1 across threshold grid.
   - Output recommended cutoffs for each source (`vision`, `ocr`, future `coreml`).
4. Source-aware fusion
   - Fuse scores by source reliability, not one global threshold.
   - Example: OCR exact token match can be high-confidence; broad classifier labels require stricter thresholds.
5. Runtime observability
   - Log bucket distributions and user overrides locally for tuning.

Acceptance:
- Thresholds are data-driven and versioned.
- Confidence behavior is predictable and test-backed.

### Workstream C: Continual Learning (Real, Not Stub)

Current gap:
- Correction APIs exist, but UI never records or applies corrections in decision flow.

Build tasks:
1. Correction capture
   - Every manual override in confirmation UI writes `(vision_label, corrected_ingredient_id)`.
2. Retrieval policy
   - Use top-voted correction per label, with tie-break by recency.
   - Gate auto-apply with min support (`count >= 2`).
3. Suggestion policy
   - For medium-confidence prompts, prioritize historically corrected label first.
4. Quality controls
   - Track correction precision (how often suggestion accepted vs rejected).
   - Add reset controls per label/global.
5. Optional advanced path
   - Evaluate updatable Core ML model (`MLUpdateTask`) only after correction-memory loop is stable.
   - Use only if model is explicitly updatable and training data schema is validated.

Acceptance:
- Corrections change future behavior deterministically.
- User can inspect/reset learned corrections.

### Workstream D: Official Data Ingestion (No LLM-only Data Source)

Principle:
- Use LLMs for drafting recipes only if needed, but nutrition/ingredient truth comes from official/public datasets and reproducible scripts.

Build tasks:
1. Source definitions
   - Primary nutrition source: USDA FoodData Central (Foundation/SR Legacy/Branded as needed).
   - Keep dataset version and source record per ingredient.
2. ETL scripts (reproducible)
   - `scripts/data/fetch_fdc.sh` (download or API fetch).
   - `scripts/data/normalize_ingredients.py` (canonical names, unit normalization, dedupe).
   - `scripts/data/build_seed_sqlite.py` (populate SQLite directly, optional JSON export).
3. Data quality gates
   - Referential integrity checks for recipe ingredient IDs.
   - Macro outlier checks and missing-field checks.
   - Duplicate ingredient/title detection.
4. Provenance and auditability
   - Add `source_name`, `source_id`, `source_version`, `updated_at` fields.
   - Keep ingestion manifest committed for reproducible rebuilds.
5. Runtime strategy
   - Continue using DB at runtime; JSON only as bootstrap artifact until full seed-db strategy lands.

Acceptance:
- Entire dataset can be rebuilt from scripts on a clean machine.
- Every nutrition value has source provenance.

### Workstream E: Personalization and Health Scoring Simplification

Goal:
- Replace scattered heuristics with a maintainable scoring system composed of explicit buckets and weighted components.

Build tasks:
1. User bucket model
   - Define stable bucket dimensions:
     - goal bucket (`weight_loss`, `muscle_gain`, `maintenance`, `general`)
     - dietary bucket (vegetarian/vegan/etc.)
     - sodium-sensitivity bucket (default/low-sodium)
     - time-preference bucket (quick/normal)
   - Persist these as normalized fields, not free-form JSON blobs only.
2. Score decomposition
   - Split recommendation score into named components:
     - `availability_score`
     - `goal_alignment_score`
     - `restriction_penalty`
     - `variety_bonus`
     - `time_fit_bonus`
   - Keep each component independently testable.
3. Weight profiles
   - Version weight sets per goal bucket (for tuning without code rewrites).
   - Keep default profile in a single config table/file.
4. Explainability
   - Return top 2-3 reasons for ranking in UI model.
   - Avoid opaque one-number ranking.
5. Query + compute boundary cleanup
   - Do filtering in SQL (allergens/restrictions/time caps), scoring in Swift.
   - Remove duplicated scoring paths.

Acceptance:
- Score changes are attributable to specific components.
- Adjusting one bucket or weight profile has predictable impact.
- Ranking logic is readable and unit-testable.

## Critical Bug Register (Found in Current Code)

### P0 Bugs

1. Incorrect correction winner selection in cache load
   - File: `FridgeLuck.swiftpm/Recognition/LearningService.swift:31`
   - Issue: rows were ordered by count descending but later rows could overwrite top correction.
   - Status: patched.

2. Lexicon maps `olive oil` to `butter`
   - File: `FridgeLuck.swiftpm/Recognition/IngredientLexicon.swift:119`
   - Issue: wrong semantic mapping distorts ingredient recognition and nutrition.
   - Status: patched (added explicit oil mappings).

3. Silent dual-pass failure can masquerade as "no ingredients"
   - File: `FridgeLuck.swiftpm/Recognition/VisionService.swift:41`
   - Issue: both passes could fail and still degrade to empty output with no explicit failure state.
   - Status: patched to surface pipeline failure when both passes error.

### P1 Bugs / Design Defects

1. Continual learning not wired from UI
   - File: `FridgeLuck.swiftpm/Features/Ingredients/IngredientReviewView.swift:112`
   - Issue: no correction recording path; `LearningService.recordCorrection` unused in flow.

2. Medium-confidence workflow lacks alternatives
   - File: `FridgeLuck.swiftpm/Features/Ingredients/IngredientReviewView.swift:112`
   - Issue: no top-N disambiguation, just toggle chips.

3. AI normalization and generation paths are commented stubs
   - Files:
     - `FridgeLuck.swiftpm/Intelligence/AIIngredientNormalizer.swift:10`
     - `FridgeLuck.swiftpm/Intelligence/RecipeGenerator.swift:27`
   - Issue: architecture implies AI extension, but implementation is non-operative.

4. Recommendation orchestration is dead code in UI flow
   - File: `FridgeLuck.swiftpm/Services/RecommendationEngine.swift:6`
   - Issue: service exists but views bypass it.
