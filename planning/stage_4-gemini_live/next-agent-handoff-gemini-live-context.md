# FridgeLuck -> Gemini Live Stage 4: Short Handoff

Last updated: 2026-03-04 (America/Chicago)

## Why this file exists

This is now a compact implementation handoff. Detailed user intent and direction were moved to:

- `planning/stage_4-gemini_live/user-direction-and-feature-intent.md`

Use that file as the primary product-direction source for stage 4.

## Current app baseline (keep stable)

FridgeLuck is an iOS Swift Playgrounds app with an offline-first core flow:

`ScanView -> IngredientReviewView -> RecipeResultsView -> CookingGuideView`

Core files:

- `FridgeLuck.swiftpm/App/AppDependencies.swift`
- `FridgeLuck.swiftpm/App/ContentView.swift`
- `FridgeLuck.swiftpm/Feature/Scan/ScanView.swift`
- `FridgeLuck.swiftpm/Feature/Ingredients/IngredientReviewView.swift`
- `FridgeLuck.swiftpm/Feature/Results/RecipeResultsView.swift`
- `FridgeLuck.swiftpm/Feature/Recipe/CookingGuideView.swift`

## What is already in place

1. Confidence-based detection routing:
   - `Capability/Core/Recognition/ConfidenceRouter.swift`
2. Deterministic ingredient-based macro math:
   - `Platform/Persistence/Services/NutritionService.swift`
   - `Platform/Persistence/Repository/UserDataRepository.swift`
3. Minimal agent seam:
   - `Domain/Ports/AgentConversationProviding.swift`
4. Stable architecture and tests:
   - `FeatureLogic` target + policy tests in `FridgeLuck.swiftpm/Tests/*`
   - CI scripts: `scripts/run_ios_tests.sh`, `scripts/run_periphery_scan.sh`

## Stage 4 architecture direction (additive)

1. `Feature/Assistant/*` for user-facing assistant flows.
2. `Capability/Agents/*` for orchestration, tool routing, confidence policy.
3. `Integration/GeminiLive/*` for provider transport and realtime mapping.
4. Preserve existing flows; do not replace scan/review/results/cooking.

## Security and platform constraints

1. Avoid raw Gemini API keys in client code.
2. Prefer Firebase AI Logic + App Check for mobile Live API posture.
3. Live tool calls require explicit client-side tool response handling.
4. Hackathon-critical paths must remain clearly compliant with Google Cloud hosting/service requirements.

## Operating rules for implementation

1. Zero regression for current user journeys.
2. Keep offline core usable even when assistant/network path fails.
3. Keep naming/folder taxonomy consistent with stage 3 architecture guidance.
4. Keep tests green; add targeted tests for new agent/inventory/confidence behavior.

## Required docs in this stage

1. Challenge requirements:
   - `planning/stage_4-gemini_live/gemini-live-agent-challenge-guidelines.md`
2. User direction and product intent:
   - `planning/stage_4-gemini_live/user-direction-and-feature-intent.md`

## External references (authoritative)

- Gemini Live docs: `https://ai.google.dev/gemini-api/docs/live-guide`
- Live tools docs: `https://ai.google.dev/gemini-api/docs/live-tools`
- Firebase AI Logic Live API: `https://firebase.google.com/docs/ai-logic/live-api`
- Firebase AI Logic App Check: `https://firebase.google.com/docs/ai-logic/app-check`
- Challenge rules: `https://geminiliveagentchallenge.devpost.com/rules`

