# Stage 4 Decision: Gemini Live Agent Architecture and Scope

Last updated: 2026-03-04 (America/Chicago)

## Why this decision exists

This document finalizes a hard scope and architecture for the hackathon build so we optimize for rubric score, not feature count.

Primary reference rubric: `planning/stage_4-gemini_live/gemini-live-agent-challenge-guidelines.md`

## Rubric-first interpretation

Based on the challenge scoring weights:

1. Innovation and multimodal UX (40%) is the biggest lever.
2. Technical implementation and architecture (30%) rewards grounding, reliability, and error handling.
3. Demo and presentation (30%) rewards a clearly working real-time system with proof of cloud deployment.

Implication: we should prioritize a tight "live + tool-using + confidence-safe" agent over broad feature expansion.

## Final scope decision (v1 for submission)

### Must ship (in scope)

1. Live multimodal assistant (voice + camera/photo) using Gemini Live API.
2. Tool-using agent on Google Cloud that can:
   - scan fridge/pantry,
   - reverse-scan cooked meal,
   - generate recipe from on-hand ingredients,
   - mutate inventory ledger safely.
3. Confidence control module that gates exactness claims:
   - exact macros only after sufficient confidence and/or explicit confirmation.
4. At least one automation loop:
   - scheduled "use soon" + restock suggestions from inventory state.

### Should ship (if time allows)

1. One external utility integration for restock workflow:
   - practical target: export shopping list to Google Sheets/Tasks/Calendar.
2. Voice-first "add your own recipe" flow with live transcript + structured extraction.

### Explicitly out of scope (for hackathon submission)

1. Full grocery checkout commerce integrations (Instacart/Walmart end-to-end purchase).
2. Fully autonomous pantry tracking without user confirmations.
3. Large multi-agent orchestration graph beyond one planner agent + tool layer.
4. Continuous always-on background camera monitoring.

## Confidence-first architecture (finalized)

### Module name

`ConfidenceControlPlane`

### Goal

Prevent the system from presenting non-deterministic guesses as exact macro accounting.

### Inputs

1. Vision detector confidences (local + cloud extraction).
2. Cross-source agreement score (local detections vs Gemini extraction vs recipe match evidence).
3. Ingredient coverage score (required ingredients matched).
4. User confirmation signals (accepted, edited, rejected).
5. Historical calibration priors per ingredient and per pipeline path.

### Output contract

`ConfidenceDecision`:

- `deterministic_ready` (bool)
- `mode` (`auto`, `review_required`, `estimate_only`)
- `confidence_score` (0-1)
- `reasons` (short structured list for UX transparency)

### Policy thresholds (initial)

1. `>= 0.92`: `auto` candidate path (still one-tap confirm before ledger mutation).
2. `0.75 - 0.92`: `review_required` (ingredient/grams review UI required).
3. `< 0.75`: `estimate_only` (no exact macro claim; ask for more evidence).

### Enforcement rules

1. "Exact macros" label is forbidden unless `deterministic_ready == true`.
2. Inventory decrement is forbidden unless user confirms final ingredient amounts.
3. Agent response formatter must include confidence rationale in final output.

## Recommended technical stack

### Client

1. Existing iOS Swift app remains primary UX surface.
2. Local recognition remains offline fallback path.

### Cloud agent backend (Google Cloud hosted)

1. TypeScript service on Cloud Run.
2. Gemini Live API session handling via Google GenAI SDK.
3. Tool router with explicit tool contracts (scan, reverse scan, recipe, inventory mutate, restock plan).
4. Firestore for session state, inventory snapshots, and confirmation logs.
5. Cloud Storage for image artifacts (optional retention window).
6. Cloud Scheduler + Cloud Run job for daily automation.
7. Cloud Tasks for retry-safe asynchronous operations (notifications, long-running enrichments).

### Security and reliability

1. Do not hardcode Gemini keys in mobile app.
2. Use Firebase AI Logic + App Check (or backend-mediated auth) for protected client access.
3. Require idempotency keys for inventory mutations.
4. Log tool calls + confidence decisions for replayable audits.

## Minimal module layout (backend)

`backend/src/`

1. `live/sessionGateway.ts` - Gemini Live session lifecycle and stream bridge.
2. `agent/systemPrompt.ts` - strict policy prompt and output schema.
3. `agent/toolRegistry.ts` - typed tool declarations and handlers.
4. `confidence/confidenceControlPlane.ts` - scoring + policy enforcement.
5. `confidence/calibrationStore.ts` - priors and reliability updates.
6. `inventory/inventoryLedger.ts` - deterministic mutation methods.
7. `automation/restockJob.ts` - scheduled use-soon/restock planner.
8. `api/webhooks.ts` - scheduler/task endpoints.
9. `observability/tracing.ts` - structured logs and traces for tool calls.

## Why cron + external tools are in scope (and how)

Yes, automations are in scope if they stay narrow:

1. They strengthen technical architecture scoring by showing real agent-tool workflows.
2. They improve demo story (proactive assistant, not only reactive chat).
3. They should be one clear loop (daily freshness + restock), not a generic automation platform.

## Implementation phases

1. Phase A (core scoring path): Live session + tool calls + confidence gating + deterministic confirm flow.
2. Phase B (high-value add): daily scheduler job + restock recommendation artifact.
3. Phase C (polish): richer voice UX, better explanation UI, stronger calibration.

## Evidence base used for this decision

1. Gemini Live API docs (real-time sessions, modalities, setup):
   - https://ai.google.dev/gemini-api/docs/live-guide
2. Gemini Live tool calling docs (function calls + responses loop):
   - https://ai.google.dev/gemini-api/docs/live-tools
3. Firebase AI Logic security posture and App Check:
   - https://firebase.google.com/docs/ai-logic/app-check
   - https://firebase.google.com/docs/ai-logic/migrate-from-google-ai-client-sdks
4. ADK capabilities and Cloud Run deployment flow:
   - https://google.github.io/adk-docs/
   - https://google.github.io/adk-docs/deploy/cloud-run
5. Cloud-native automation patterns:
   - https://cloud.google.com/scheduler/docs
   - https://cloud.google.com/run/docs/triggering/using-scheduler
6. Cloud Run production checklist:
   - https://cloud.google.com/run/docs/tips/general
7. Reputable Google-maintained implementation examples:
   - https://github.com/google-gemini/live-api-web-console
   - https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/multimodal-live-api/project-livewire
   - https://github.com/google/adk-samples/tree/main/python/agents/realtime-conversational-agent

## Final call

To maximize hackathon score, we should build one excellent confidence-safe live multimodal agent with real tool execution and one proactive automation loop, not a broad smart-fridge platform with many partial features.
