# FridgeLuck Stage 4: User Direction and Feature Intent

Last updated: 2026-03-04 (America/Chicago)

## Purpose

This file is the authoritative capture of:

1. The user's product direction for Gemini Live work.
2. The user's wording-level intent (accurate interpretation, not generic summary).
3. Scope decisions made during planning.
4. Practical constraints for implementation.

For future work in stage 4, prefer this file over long-form exploratory handoff notes.

## User's Core Product Vision (Accurate Interpretation)

FridgeLuck should become a Gemini Live powered smart fridge assistant that is materially more accurate than apps that "guess" calories/macros from photos. The central differentiation is ingredient-level accounting:

1. Know what ingredients are actually in a recipe.
2. Track how much of each ingredient is used.
3. Use that to produce deterministic macro totals instead of loose estimates.

The user wants the app to work as a real smart-fridge assistant:

1. Analyze fridge and pantry photos to identify available food and what remains.
2. Recommend recipes that use what is on hand.
3. Track depletion and freshness/shelf life.
4. Recommend "use soon" actions before food goes bad.
5. Help planning for events (guests), including missing grocery items.
6. Learn from ratings and meal outcomes to improve recommendations.
7. Support both guided cooking and fast logging (photo-based reverse scan).
8. Support voice-first input with Gemini Live for creating/logging recipes.

## User's Explicit Feature Priorities

The user called out these primary features:

1. Recipe generation with live photo-based grounding.
2. Confidence-based detection and confidence-aware generation/calculation.
3. Smart fridge tracking and reverse-scan opportunities similar to Cal AI + MyFitnessPal style workflows, but with better ingredient-grounded accuracy.

## Decisions Captured During Planning

### Delivery and architecture direction

1. Primary target: live demo core for hackathon deadline reliability.
2. Assistant should be additive, not a rewrite of existing scan/review/results/cooking flows.
3. Preferred topology: hybrid realtime, with secure Gemini Live integration and backend tooling.
4. Inventory truth model: verified ledger approach (quantity plus confidence, with user confirmation points).

### Macro accuracy and reverse scan

1. User preference language: "always exact claim."
2. Operational enforcement selected: confirm-to-finalize.
3. Interpreted product behavior:
   - Model proposes dish + ingredients + grams.
   - User can edit quickly.
   - High-confidence paths should be one-tap/low-friction.
   - Exact macro labeling and inventory mutation occur after confirmation.

### Reverse-scan flow preference

User requested a hybrid strategy:

1. Try recipe match first.
2. If no strong match, perform ingredient decomposition.
3. Allow fuzzy overlap when useful.
4. Ask user to confirm portion size and inferred ingredients.
5. Persist new recipe variants when no clean existing match is found.

### Assistant surface and modalities

1. Dedicated assistant entry surface is preferred.
2. Mode priority:
   - First, traditional assistant flow with photo multimodality.
   - Then, continuous camera stream plus voice for accessibility and immersion.
3. Text input is not the primary interaction mode, but optional text recipe search can be added later.

### Smart-fridge v1 boundary

1. Chosen scope: core foundation plus spoilage alerts/use-soon nudges.
2. Full grocery commerce and advanced scheduling are important ideas but not core v1 deliverables.

## User-Provided Constraints and Quality Bar

1. Direction and wording matter; preserve intent precisely in planning and execution.
2. Avoid non-deterministic "guessing" claims for macro math.
3. Keep confidence UX aligned with existing app patterns (auto/confirm/possible style and fast acceptance of high confidence).
4. Favor realistic implementation scope over speculative complexity.

## Current Codebase Context (Only What Matters for Stage 4)

1. App type: iOS Swift Playgrounds package (`FridgeLuck.swiftpm`).
2. Existing critical flow:
   - `ScanView -> IngredientReviewView -> RecipeResultsView -> CookingGuideView`
3. Existing confidence routing already exists in:
   - `FridgeLuck.swiftpm/Capability/Core/Recognition/ConfidenceRouter.swift`
4. Existing macro/accounting foundation already exists in:
   - `FridgeLuck.swiftpm/Platform/Persistence/Services/NutritionService.swift`
   - `FridgeLuck.swiftpm/Platform/Persistence/Repository/UserDataRepository.swift`
5. Existing agent seam exists (minimal) in:
   - `FridgeLuck.swiftpm/Domain/Ports/AgentConversationProviding.swift`

## External Constraints (Relevant to User Decisions)

1. Hackathon requires Gemini model usage and Google Cloud service usage.
2. Hackathon requires agents hosted on Google Cloud.
3. Mobile security posture should avoid raw API key embedding in app clients.
4. Firebase AI Logic + App Check is a practical secure mobile path for Live API integration.
5. Live tool calling requires explicit client-side tool response handling.

## Working Interpretation for Implementation

Use a two-speed build strategy:

1. Ship a robust, judged demo path first:
   - photo-grounded live assistant,
   - reverse scan with confirm-to-finalize exactness,
   - inventory ledger plus spoilage nudges.
2. Keep continuous stream, expanded planning, and commerce as near-term follow-on work unless time and reliability permit.

## Platform Interpretation from Research (GCP vs Convex)

User intent includes strong preference for TypeScript and interest in Convex for realtime. Research-backed interpretation:

1. Convex can technically be used from Swift/iOS and can be run in parallel.
2. For this hackathon, judged core agent paths should remain clearly GCP-hosted and GCP-service backed to avoid compliance ambiguity.
3. Pragmatic stage-4 default:
   - GCP-first for competition-critical flows.
   - Keep Convex as a post-hackathon or secondary-path option unless time/risk profile materially improves.

This interpretation reflects both user preference and challenge constraints, not a dismissal of Convex.

## Source Links Used for Stage 4 Direction

Challenge and Gemini/Firebase:

1. `https://geminiliveagentchallenge.devpost.com/rules`
2. `https://ai.google.dev/gemini-api/docs/live-guide`
3. `https://ai.google.dev/gemini-api/docs/live-tools`
4. `https://firebase.google.com/docs/ai-logic/live-api`
5. `https://firebase.google.com/docs/ai-logic/app-check`
6. `https://firebase.google.com/docs/ai-logic/migrate-from-google-ai-client-sdks`

Convex capability/deployment references:

1. `https://docs.convex.dev/client/swift`
2. `https://docs.convex.dev/production`
3. `https://docs.convex.dev/self-hosting`
4. `https://docs.convex.dev/cli/local-deployments`

## Status

This document is actively intended to replace long exploratory notes as the main source of user intent for stage 4.

## Implementation Status Snapshot (2026-03-04)

Implemented in code (current):

1. Confidence-routed ingredient review remains the front door for exactness.
2. Smart-fridge inventory ledger tables and repository are live.
3. Cooking completion now consumes inventory lots.
4. Confirmed scan results now ingest inventory lots with confidence-aware intake.
5. Home now surfaces "use soon" freshness nudges from inventory expiry windows.
6. Reverse-scan foundation now exists:
   - meal photo analysis,
   - confidence-scored recipe candidate matching,
   - confirm-and-log flow with inventory consumption.
7. Recipe results now surface a live recipe idea card from current generation pipeline.

Still pending for full target vision:

1. Full Gemini Live transport/session tool-calling implementation in production path.
2. Voice-first assistant UX and continuous multimodal session.
3. Stronger reverse-scan ingredient/gram editing before finalization.
