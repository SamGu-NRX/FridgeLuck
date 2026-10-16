# LeChef: more than a chat — spec

Status: draft for Sam, 2026-10-15. Packet `burst5-fridgeluck-spec-lechef`, base `alpha` (merge 0309dd1).

LeChef today is a transcript with a camera. This spec turns it into the cooking companion PR #86 §4 defines: five jobs — **plan, substitute, coach, adapt, remember** — each with a local core that works offline, the phone authoritative and the model only proposing, chat demoted to a fallback behind a transcript toggle, timers on the device, and push-to-look versus continuous camera as scored candidates.

Sam's guard rails hold throughout (`planning/stage_0-brainstorm/fridgeluck planning.md:1205`): LeChef is not a social platform to perform cooking for likes, not a diet app that judges, not a recipe database to search. Concretely: LeChef cooks *your* dinners from *your* kitchen, keeps what it learns on the phone, and never makes you browse.

Companion files: `contracts/` (JSON Schemas, examples, `check.py`), one `mocks-in-words` section per surface (§12 here). Specs this one defers to: `docs/spec/recipes/` owns the recipe bundle and the step shape (§8 marks the reconciliation), `docs/spec/taste/` owns TasteEvent kinds and payloads (§13 lists what we emit).

---

## 0. Today, on alpha — evidence

Everything below was read on `alpha` at 0309dd1 unless a PR number is given.

| What exists | Where | What it implies |
| --- | --- | --- |
| A 777-line transcript-first screen: mic, transcript composer toggle, end. The transcript is the product. | `apps/ios/Feature/Assistant/LiveAssistantView.swift` (transcript section 604–631, transcript toggle 334–346, mic 326–333, End 348–355) | Chat is the whole surface; there is no cook mode, no plan, no receipt. |
| Continuous camera: frames stream whenever the session runs, throttled only by a send interval. | `apps/ios/Feature/Assistant/LiveAssistantCaptureCoordinator.swift:7–17` (`AVCaptureSession`, `onVideoFrame`, `lastFrameSentAt`) | Camera is on by default; push-to-look is a change of model, not a flag. |
| Frames, audio turns and session context flow over a WebSocket envelope client. | `apps/ios/Integration/GeminiLive/GeminiLiveSessionClient.swift` (`sendImageFrame` 119–125, `beginAudioTurn` 131, `sendAudioChunk` 140–149, `sendSessionContext` 61–103) | The transport is reusable; the *policy* of what is sent is what changes. |
| The backend persists the latest camera frame to Firestore, where it outlives the session. | `backend/gemini-agent/src/session/liveSessionStore.ts:242–256` (`recordLatestFrame` merges `latestCameraFrame` into the session doc); read back in `fromDoc` 299–325 | Privacy problem this spec removes (§9). |
| The backend also persists the last user message and a 30-entry audit tail. | `backend/gemini-agent/src/session/liveSessionStore.ts:265–293` (`appendMutationAudit`, `recordUserMessage`) | Same problem, lesser severity; same fix. |
| Backend tools act on the world directly: inventory mutations execute server-side with an idempotency key. | `backend/gemini-agent/src/agent/toolRegistry.ts:25–45` (`get_recipe_context`), 47–76 (`assess_live_scene`), 78–93 (`ground_food_safety`), 95+ (`mutate_inventory`) | The model's backend is authoritative today. Inverted in §2. |
| The cooking guide is string steps: instructions parsed line-by-line, step numbers stripped, a source line becomes attribution. Completion is a set of toggled indices. | `apps/ios/FeatureLogic/Recipe/CookingGuideSteps.swift:10–52`; `apps/ios/FeatureLogic/Recipe/CookingGuideStateTransitions.swift:3–23` | No structured steps, no timers, no quantities in steps: the coach job's raw material does not exist yet (§8, §12). |
| Substitutions are an in-code static map of ingredient-ID pairs with a gram ratio and a diet-reason badge. No recipe context, no allergen closure, no compound ingredients. | `apps/ios/Platform/Persistence/Services/SubstitutionService.swift:7–58` (reasons), 64–74 (`Substitution`), 80–117 (map + lookup) | The swap sheet needs a reviewed, context-aware, allergen-checked table (§6, §7). |
| Recipe generation is an on-device Foundation Models call returning one text blob of instructions. | `apps/ios/Capability/Core/Intelligence/RecipeGenerator.swift` (`AIGeneratedRecipe`, `AIRecipeGenerator`) | Generated recipes are outside this spec's jobs except as RecipeRefs the plan may propose. |
| There is no timer subsystem, no cook-session persistence, no `Database/Subsystems/` directory. | `grep -r "Timer" apps/ios/FeatureLogic apps/ios/Feature` → no cooking timers; `apps/ios/Platform/Persistence/Database/` holds only `AppDatabase.swift` and `Migrations.swift` | Timers and the cook session are net-new (§4, §11). |
| No `docs/` exists on alpha at all; the overhaul spec and its mocks live on `docs/spec-overhaul-20261011`. | `git ls-tree origin/docs/spec-overhaul-20261011` | This spec creates `docs/spec/lechef/` on alpha per the shared contracts. |

Binding inputs adopted as-is from PR #86 (the overhaul spec on `docs/spec-overhaul-20261011`):

- **§4 five jobs table** — plan / substitute / coach / adapt / remember, each with a local core that always works and a Gemini Live layer on top.
- **§3.1 food safety** — doneness as thermometer tests, camera looks never give safety verdicts, adapt changes time only under reviewed rules, every substitution rechecks all eaters' allergens including compound ingredients, swaps describe the difference and never promise "no change".
- **§3.2 pantry truth** — allocation from eligible lots without double counting, line states `sufficient / short / quantity unknown / assumed staple / needs reconfirming`, fit lines never a percentage.
- **§3.4** — LeChef's backend keeps no frames and no transcript beyond the live session.

---

## 1. Decision log (each: two alternatives, one pick)

**D1 — Where LeChef's product lives.** (a) Keep one chat surface and embed cards in the transcript. (b) Give each job its own surface — full-screen cook mode, plan sheet, swap sheet, rescue card, remember receipt — and leave chat as a fallback behind a transcript toggle. **Pick (b)**, per PR #86 §4 (binding). Rejected (a): cards in a scrollback are unreadable at arm's length, die with the session, and make every job hostage to a model round-trip; the transcript screen is already 777 lines of chrome trying to be everything (`LiveAssistantView.swift`).

**D2 — Who is authoritative.** (a) Backend-authoritative: tools mutate server state as today (`toolRegistry.ts` `mutate_inventory`), the phone mirrors. (b) Phone-authoritative: the backend reads bounded snapshots and emits typed *proposals*; the phone checks, executes on user approval, and returns *receipts*. **Pick (b)**, per PR #86 §4 and PRs #39/#26's direction. Rejected (a): server-side writes can't see the pantry truth on the phone, create a second write authority, and can't work offline — and a voice transcript must never be able to log a meal or share anything.

**D3 — Cook-mode camera.** (a) Continuous camera while cooking (today's behaviour, `LiveAssistantCaptureCoordinator.swift:7–17`). (b) Push-to-look: one frame or ≤3 s clip, only on "Show it" or the viewfinder button. **Pick (b) as the default that ships; (a) stays a candidate** scored in the eval suite (§10) on job success, frames sent, cost per cook, and on-device heat — Sam decides (overhaul §10.5, voice opt-in until a cost budget exists). Rejected as default: (a) spends privacy and battery for availability the user didn't ask for, and the mock's rule is right — "the camera is never on by itself".

**D4 — Voice.** (a) Full free-form voice through Gemini Live. (b) A five-word local vocabulary — *next, back, repeat, timer N minutes, show* — with touch equivalents always present, Live answers only in the LeChef line. **Pick (b)** per PR #86 §4; free-form questions are what the LeChef line is for, parsed by Live, never required.

**D5 — Steps.** (a) Define a LeChef-private step shape now. (b) Adopt the recipe spec's bundle v2 step shape. **Pick (b)**; the branch `obv/burst5-fridgeluck-spec-recipes` did not exist when this spec was written (checked `git ls-remote` 2026-10-15), so §8 defines the minimum LeChef needs, marked **RECONCILE with the recipe spec** — the cook-core slice consumes the recipe spec's shape when it lands and LeChef's parsers are adapters, not owners.

**D6 — Plan storage.** (a) Plans live only in the view layer. (b) Plans persist locally (`cook_plan*` tables) with pantry-truth line states frozen at acceptance. **Pick (b)**: the remember job and the week-4 utility metric both need "what did we actually cook from the plan"; a plan that evaporates can't be remembered.

**D7 — Evaluation spend.** (a) Scripted fake-model suite only. (b) Fake-model suite as the gate, plus opt-in real Gemini runs with a hard spend cap. **Pick (b)**: fake models catch logic, not prompt rot; a capped real run catches it once a release. No paid calls in tests — CI and unit tests run fakes only (§10).

---

## 2. The five jobs

The contract every job keeps (PR #86 §4, binding):

1. The **local core** runs with no network. Gemini Live is a layer over it, never a dependency under it.
2. The **phone is authoritative** for pantry, cook sessions and logs. Backend tools read bounded snapshots and propose typed actions; the phone checks revision and approval, executes, and returns a receipt. The model cannot manufacture approval; a voice transcript alone never authorizes a meal log or a share.
3. Every Gemini-visible action is **small, typed and reversible-or-expiring**; anything irreversible requires the UI, not voice.

| Job | Local core (always works offline) | Gemini Live adds | Offline / failure behaviour |
| --- | --- | --- | --- |
| **Plan** | Deterministic allocation of current stock across the next 3 dinners + a short shopping list, reserving quantities across the plan (§7) | "Next three dinners from what I have" in words; preferences ("nothing with coriander"), trade-offs ("swap Tuesday's fish — it's for Thursday") | Allocation is pure Swift; Live offline → the sheet opens with the computed plan and no conversational refinement. |
| **Substitute** | Reviewed swap table shipped in the bundle, local lookup, allergen recheck for every eater including compound ingredients (§6) | Reasons beyond the table when it has nothing, labelled "not a reviewed swap" before the user accepts | Table lookup is on-device; Live unavailable → only reviewed swaps are offered, which is the safe default. |
| **Coach** | Steps, timers on the device with persisted deadlines, the five-word vocabulary + touch equivalents (§4) | One-line step-relevant answers ("Want a 2 min timer to check again?"), reads the step aloud, camera look on request | The mock's banner is the contract: "LeChef is offline. Steps and timers still work." Voice falls back to on-device recognition of the five words; the LeChef line hides. |
| **Adapt** | Amounts rescale predictably from servings and quantity evidence; time changes only under reviewed rules (§5) | Explains the change in one line, proposes the equipment check | Pure arithmetic + rule table; Live offline → rescale happens silently-safe, step caption states what changed, no conversational explanation. |
| **Remember** | Rating + one-line note saved locally with a visible receipt (§3.6) | Note by voice, transcribed, shown for confirmation before save | Save is local-first; transcription unavailable → keyboard entry, which is the primary path anyway. |

What **chat still does** (§3.7): open-ended questions while cooking or planning ("what can I do with the rest of this fennel"), camera-look answers, and anything the five-word vocabulary can't carry. It is behind a transcript toggle in cook mode and the entry point in plan context. It is never the only path to an action.

---
