# LeChef: more than a chat — spec

Status: draft for Sam, 2026-10-15. Packet `burst5-fridgeluck-spec-lechef`, base `alpha` (merge 0309dd1).

LeChef today is a transcript with a camera. This spec turns it into the cooking companion PR #86 §4 defines: five jobs — **plan, substitute, coach, adapt, remember** — each with a local core that works offline, the phone authoritative and the model only proposing, chat demoted to a fallback behind a transcript toggle, timers on the device, and push-to-look versus continuous camera as scored candidates.

Sam's guard rails hold throughout (`planning/stage_0-brainstorm/fridgeluck planning.md:1205`): LeChef is not a social platform to perform cooking for likes, not a diet app that judges, not a recipe database to search. Concretely: LeChef cooks *your* dinners from *your* kitchen, keeps what it learns on the phone, and never makes you browse.

Companion files: `contracts/` (JSON Schemas, examples, `check.py`), one `mocks-in-words` section per surface (§12 here). Specs this one defers to: `docs/spec/recipes/` owns the recipe bundle and the step shape (§8 marks the reconciliation), `docs/spec/taste/` owns TasteEvent kinds and payloads (§13 lists what we emit).

---

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

---

## 3. Surfaces outside chat

Six surfaces. Entry points are by user intent, not tab position — the app shell is decided in the separate UI redesign (overhaul §5), so every entry below names the *intent* that opens it, wherever that control lives.

### 3.1 Cook mode (full screen)

**Purpose.** Hands-busy, eyes-busy cooking: one step, its timers, and a way forward that never requires reading a paragraph.

**Entry points.** Intent "I'm cooking this now": the cook button on a recipe detail; "Cook tonight" on a planned dinner; resuming an active session ("continue where I left off"); a fired timer notification while no session is open ("open the cook").

**Layout, top to bottom.** (From `mocks/cook-lechef.html`, corrected for this spec.)

1. Close (X, 44 pt) · recipe title · elapsed time in mono.
2. Progress segments — one per step; done = ink, current = yolk, upcoming = dim.
3. Step number ("4") in yolk mono + the step text, the largest text in the app (26/32 pt, scales with Dynamic Type), quantities and times highlighted as mono on a yolk-soft block so they can be found without reading the sentence. Safety-check steps render the checkable test, never colour or time alone: "Check the thickest piece of chicken: 74 °C in the middle." (PR #86 §3.1.)
4. Timer tiles, grid 2-up: 44 pt mono digits, linear drain ring, tap to pause, long-press to remove, a "Timer" tile to add one. A fired tile fills yolk, reads 0:00, rigid haptic + sound, and the fill fades on tap or on "next"/"repeat".
5. The LeChef line — one line, only when step-relevant, at most two answers as buttons ("Show it", "No"). This is where Live lives. Hidden entirely when offline; replaced by the viewfinder during a look.
6. Voice row: amplitude bars (or a static mic-slash when voice is off / mic denied — never a fake pulse), hint "Listening. Say next, back, repeat, show, or timer 3 minutes."
7. **Next** — 64 pt tall, full width, shows the *next* step's short name ("Next 5 · Stir in the sauce") so the decision can be made without pressing. **Back** is a text link (it is rare).

**States.** First run: a one-time spotlight on Next and the voice row, dismissed by any tap. Empty: cook mode cannot be empty — it is always inside a session (§4). Loading: step data is local; the only loading state is the camera look ("Looking at the pan", ≤3 s, then the answer or "I couldn't see it clearly"). Offline: banner above the voice row, "LeChef is offline. Steps and timers still work."; Live line hides; local voice fallback. Error (Live): same as offline, one line, never a modal. Partial data: a recipe with string steps only (no structured times) renders steps and Next, no timer tiles, and the "Timer" tile opens a plain count-up sheet instead of a suggested duration. Interrupted (app kill / lock): reopening returns to the same step with timers still counting (§4). Complete: after the last step — paper background returns, dish name, "Cooked in 27 min", kcal counting up once, 1–5 rating row, "One line for next time" (voice or keyboard), optional photo picker, "Done". Nothing else; no confetti. Leave: X asks once — "Leave this cook? Timers keep running." Leave / Stay.

**Voice vocabulary and touch equivalents** (full table in §4.3).

**Accessibility.** All primary controls 64 pt in cook mode (44 pt minimum elsewhere); Next and timer tiles have VoiceOver labels ("Next: stir in the sauce", "Noodles timer, 1 minute 42 remaining, running"); the drain ring is decorative (`accessibilityHidden`), the value is in the label and updates on significant change; Dynamic Type to XXL reflows the step block (step text never truncates — it scrolls); VoiceOver rotor for timers; Reduce Motion replaces crossfades with 150 ms fades and never animates the ring pulse; haptics respect system settings; the voice row is meaningless to VoiceOver users and is marked as such ("Voice control, audio only").

### 3.2 Plan sheet

**Purpose.** Answer "what are our next three dinners from what I have" with a shopping list that is honest about what's short.

**Entry points.** Intent "decide the next few days": the Tonight decision point ("Plan the next 3 dinners"); voice intent "plan dinners"; after a cook completes ("plan the next ones?").

**Layout, top to bottom.**

1. Title: "Next three dinners". Sub-line with pantry truth date: "From your kitchen, last confirmed Tuesday."
2. Three dinner cards in cook order: dish name, RecipeRef, servings stepper, time, and the fit line computed per PR #86 §3.2 — "9 of 10 · 1 swap" only when nine lines are truly sufficient; otherwise "7 recorded · check eggs and oil". Never a percentage.
3. Per-dinner line states, expandable: each line shows its state — sufficient · short ("need 2 eggs") · quantity unknown · assumed staple ("oil — assumed") · needs reconfirming ("yoghurt, opened 6 days ago"). Swaps offered where the reviewed table has one ("Swap sour cream → Greek yoghurt · a little tangier").
4. Shopping list: only the shortfall across all three dinners after swaps, merged by ingredient with compatible units ("eggs ×4, spinach 200 g"). Staples the user has marked "always have" appear struck through with "you usually have this".
5. LeChef line: one sentence of reasoning, and the two answers ("Why this one?", "Something else").
6. Actions: "Save plan" (primary), "Regenerate" (text link).

**States.** First run (kitchen never scanned): the sheet does not fake it — "I don't know your kitchen yet. Add what you have, or scan your shelf." with a manual-entry primary action. Empty (no feasible dinners): honest states per PR #86 §2 — a shopping-list-first plan, or pick from saved recipes; never a fake "cook with 2 swaps". Loading: allocation is local (<100 ms); the Live refinement shows a one-line shimmer. Offline: identical minus the LeChef line. Error: Live failure never blocks the sheet. Partial data: recipes with unknown-quantity lines keep those lines in "quantity unknown" state and the shopping list says "check what you have".

**What each interaction changes.** Accept a swap → re-runs allocation with the substitute, line states recompute, shopping list updates. Change servings → re-runs allocation for that dinner. Save plan → persists `cook_plan` + dinners + frozen line states (§11), emits taste event, reserves the stock across the three dinners. "Why this one?" → one-line reason from the allocation's own inputs (use-soon first, then taste) — not from Live when offline.

**Accessibility.** 44 pt targets; fit lines are text, not colour-only; VoiceOver reads dinner cards as one element with a summary and offers per-line rotor navigation; Dynamic Type to XXL collapses cards to stacked rows.

### 3.3 Swap sheet

**Purpose.** Replace an ingredient with a reviewed alternative — checked against every eater before it is offered.

**Entry points.** Intent "I don't have X" or "X doesn't work for someone": the swap action on a plan line, a plan card, or a cook-mode ingredient highlight; the "Short" line state; LeChef's substitution proposal.

**Layout, top to bottom.**

1. Context line: "Instead of sour cream, for Tacos (2 eaters)".
2. Reviewed swaps first: substitute name, amount ("use 180 g for 200 g"), the difference in words ("a little tangier, less rich") — never "no change" (PR #86 §3.1), and an allergen strip: "Safe for both eaters" or the blocked reason ("Contains wheat via soy sauce — blocked for Ada").
3. Unreviewed Live suggestions, visually separated, labelled: "LeChef's idea — not from the reviewed table", always preceded by the same allergen recheck; a suggestion that cannot be proven allergen-clean is shown struck through with the blocker, not as a choice.
4. Actions: "Use this" per option; "Cancel".

**States.** Empty: "No reviewed swaps for this one." + the Live option only if it passed the recheck. Offline: reviewed only. Error: table-only, silently (this is a downscale, not an alert). Partial: a swap whose substitute has no quantity conversion shows "check amount" and defaults to 1:1 with the caption "verify".

**What each interaction changes.** "Use this" → records the substitution on the session/plan, re-runs allocation or re-renders the step quantity, emits `lechef.swap_*` taste event, and the cook-mode step shows "Changed: Greek yoghurt, a little tangier" in yolk-ink.

**Accessibility.** 44 pt rows; the allergen strip is text + icon, never colour alone; VoiceOver announces blocked swaps as "dimmed, blocked" with the reason; Dynamic Type to XXL.

### 3.4 Use-soon rescue

**Purpose.** Turn "this is going bad" into tonight's dinner, not a guilt card.

**Entry points.** Intent "use things up": the use-soon banner on Tonight ("2 things need using: yoghurt, spinach"); a notification the morning an item hits its use-by horizon; the Kitchen list's use-soon filter.

**Layout.** A card, not a screen: "Yoghurt opened 5 days ago · spinach 2 days left" · one suggested recipe that consumes both with its fit line · "Cook this" · "Something else" · "Not this time" (never a counter of wasted food — not a diet app that judges). "Cook this" opens cook mode with the rescue recipe; the rescue records which use-soon items it consumed so Tonight's banner clears.

**States.** Empty: no card. Loading/offline: the suggestion is local ranking; nothing to load. Error/partial: if no feasible recipe consumes the items, the card says so and offers the plan sheet instead.

**Accessibility.** 44 pt targets, VoiceOver label summarises urgency in words ("spinach, 2 days left"), Dynamic Type to XXL.

### 3.5 Remember receipt (after-cook)

**Purpose.** Close the loop: what got cooked, what changed, what to remember — one screen, saved locally, shown once.

**Entry points.** End of cook mode (complete state); a notification an hour after a session's last timer fired ("How did it go?") if the phone never showed the complete state.

**Layout, top to bottom.**

1. "Chicken udon — cooked in 27 min · 2 servings" (mono numbers).
2. What changed, as a receipt: lines for each swap ("Sour cream → Greek yoghurt — a little tangier"), adaptations ("Scaled to 3 servings; cook time unchanged"), and timers skipped or re-checked. This is the same data the cook session logged — the receipt is a view of the record, not a new write.
3. Rating row, 1–5.
4. "One line for next time" — keyboard field, or voice with the transcription shown for confirmation before save.
5. "Save" (primary) · "Skip".
6. After save: a confirmation line, "Saved on this phone" — and that's all. Nothing shares or syncs without a separate, previewed action (PR #86 §3.4).

**States.** Loading: none (all local). Offline: identical. Error: save failure shows "Couldn't save — try again", never silently drops. Empty: the receipt section hides when nothing changed; the screen is then rating + note + save.

**What each interaction changes.** Save → writes `cook_remember` (§11), emits `lechef.remember_saved`, marks the session remembered, updates the use-soon banner if applicable.

**Accessibility.** 44 pt rating targets with value announcements; the voice field states it is recording; Dynamic Type to XXL.

### 3.6 Chat (what remains)

**Purpose.** The open-ended layer: questions the vocabulary can't carry, camera-look answers, planning refinements in words.

**Entry points.** The transcript toggle in cook mode (composer icon); the LeChef line's "Ask" affordance; the plan sheet's LeChef line. Full transcript browsing stays available behind the toggle as today (`LiveAssistantView.swift:604–631`).

**Contract.** Chat proposes; surfaces dispose. A chat answer that wants to change anything arrives as a proposal (§8) and appears on the relevant surface for approval. Chat cannot pin timers, cannot save a note, cannot log a meal — those are surface actions.

---

## 4. Cook session state machine

### 4.1 States

```
idle ── start(recipeRef, servings, eaterIDs) ──▶ cooking
cooking ── complete(lastStep) ──▶ remembering
cooking ── abandon ──▶ abandoned
remembering ── save|skip ──▶ remembered
```

- `cooking` carries `currentStep: Int` (0-based), `completedSteps: Set<Int>`, `adaptations`, `substitutions`, `startedAt`.
- `paused` is a timer-level concept, not a session state: a paused session is still `cooking`; the app renders it identically and the timers know they're paused. (Alternative: a `paused` session state blocking all input. Rejected: pausing a cook in real kitchens is per-burner, not global, and a second state multiplies every transition.)
- `remembering` persists across app kills: an unfinished receipt re-appears on Tonight ("how did it go?") for 24 h, then auto-resolves to `remembered{skipped}`.
- `abandoned` keeps the record (events, receipts of what was logged) but is not a failure — the remember receipt is still offered if ≥2 steps completed.

### 4.2 Transitions and durability

- Every transition writes the session row in the same transaction as the state change (GRDB, one queue — PR #86 §7). A kill at any point loses at most the current step's uncompleted toggles.
- **Timers survive an app kill.** A timer is a row: `{id, sessionID, label, deadline: Date (absolute), pausedAt: Date?, remainingWhenPaused: Duration?}`. The deadline is absolute wall-clock. Scheduling: `UNUserNotificationCenter` notification at the deadline at creation time; on relaunch the session store recomputes remaining = deadline − now; if the deadline passed while dead, the timer presents as fired (notification already did its job). Pause stores `remainingWhenPaused` and cancels the notification; resume recomputes a new absolute deadline. The model never creates the timer — the device does, and only then is the timer acknowledged (PR #86 §4).
- `complete` is reachable only from the last step; the Next button there reads "Finish · Cooked in N min".
- Voice "next"/"back" and touch Next/Back are the same reducer calls; the voice parser (§4.3) produces intents, never direct mutations.

### 4.3 Voice vocabulary and touch equivalents

| Voice | Grammar (local parser, offline) | Touch equivalent | Result |
| --- | --- | --- | --- |
| next | `next` (also "done", "okay", "yep" mapped to next by Live, not by the local parser) | Next button (64 pt) | advance step; mark current completed |
| back | `back`, `go back` | Back text link | previous step; unmark |
| repeat | `repeat`, `again`, `say that again` | step number tap | re-speak the step text; re-render |
| timer N minutes | `timer (N) minutes`, `timer (N) min`, `N minutes` (N: 1–180, integer or decimal) | "Timer" tile → sheet with suggested duration from the step | create device timer named for current step; acknowledged after device creation |
| show | `show`, `show it`, `look`, `look at this` | viewfinder button in the LeChef line | push-to-look: ≤3 s capture → answer |

Local parsing order: the five-word parser runs first on the partial transcript; if it matches, the intent fires even if the Live session is down. Anything else is forwarded to Live as a free-form turn; if Live is down, the UI answers "Offline — say next, back, repeat, show, or timer N minutes." Numbers: "timer three minutes", "timer 3 mins", "timer 1 and a half minutes" → 90 s; fractions up to halves and quarters.

### 4.4 Failure behaviour summary

Live disconnect mid-cook → banner + local fallback (§3.1). Timer notification denied → timers still fire in-app while the session is open, and the app warns once: "Allow notifications so timers work with the screen off." Clock change/timezone jump → timers recompute from absolute deadlines; a backwards jump > 60 s pauses timers and asks. Storage failure at session write → the cook continues in memory and retries on next transition; the receipt shows "This cook wasn't saved" if the failure persists.

---

---

## 5. Adapt (scaling, time, equipment)

**What adapts.** Servings and explicit quantity evidence ("one breast, not two", "I only have 300 g pasta") — never an invented mass. Quantities carry evidence per the recipe corpus contract (weighed · source grams · household measure with a conversion · unknown); unknown quantities rescale to the same *unit text* ("2 cans → 3 cans") or hold at "check amount" when the unit isn't countable.

**Amounts.** Linear in servings by default. Three reviewed exceptions live in a small shipped rule table (`scaling-rule` entries in `contracts/scaling-rules.schema.json`), keyed by ingredient class:

| Rule | Class | Behaviour | Example |
| --- | --- | --- | --- |
| `to-taste` | salt, pepper, chili, lemon juice, "seasoning" | do not scale; caption "season to taste — didn't scale" | 2 servings → 6 servings keeps "1 tsp" |
| `sub-linear` | strong aromatics for long simmers (dried herbs, garlic past quantity 6 cloves) | scale at √(new/old), rounded to ¼ tsp | ×4 servings → ×2 herbs |
| `count-hold` | countable items where pan geometry binds (eggs for a frittata above pan capacity) | scale, but attach an equipment check (below) | 4 → 8 eggs flags the pan |

**Time.** A time changes **only** when a reviewed rule supports it (PR #86 §3.1). The rule table has three time rules, each with a source and a bound:

- **thickness** (steaks, chicken breasts pounded or not): only when the recipe states thickness and the user changed it;
- **pan size** (equipment rule below): deeper or wider pan → check earlier, cap ±25 %;
- **quantity in the pan** (two trays, two pans): batch time roughly unchanged per batch, total time +N batches; a single doubled pan load → "check, don't trust the timer".

Outside those, the step keeps its time and the caption says what the mock says: "Changed: 1 breast, same check: 74 °C" — the check stays checkable. Never a silent time change; never a percentage of doneness.

**Equipment.** Equipment comes from the recipe spec's step/equipment fields (RECONCILE, §8) or from a shipped per-recipe equipment list. Adapt checks: pan capacity (servings × volume per serving vs. stated pan), oven dish geometry, hob rings ("needs 2 pans — you noted 1"). Failure is a caption + a check, never a block: "6 servings won't fit one pan — use two, the sauce will reduce faster."

**Interaction and contract.** Adapt is a local reducer: `(session, AdaptInput) -> CookSessionMutation`, emitted as an applied change (audit row), rendered as the yolk-ink caption, and reported on the remember receipt. Live explains the change in one line when connected; offline the caption alone is the explanation. A Live *proposal* to change a quantity or time follows the §8 proposal contract and is approved on the surface, never executed by voice.

---

## 6. Substitutions

**The table ships in the app.** PR #114's reviewed table is adopted as a bundled JSON resource compiled into the app target (not fetched): `data/substitutions/pairs.json` (schema 1.1.0 — 279 cited pairs across 11 functional roles, a 381-ingredient registry with USDA SR Legacy identities, 13 restriction definitions; all OPEN-draft numbers from the PR body, re-verified against the diff on 2026-10-15). A pair is `(original, role, substitute)` — *context is structural, not free text*: the pair carries role fit (`supported_also`, each with its own evidence status and ratio), explicit role failures (`fails` with `kind: functional|conditional` and restriction scoping), required `preparation` changes, a one-sentence `difference`, and `source_ids` (≥1 per pair, validator-enforced). Evidence statuses are `sourced / convention / conflict / unsupported / unknown`, and `ContextRules.verdict` maps them to `verified | plausible | unknown | unsupported` — `unknown` is never upgraded to fit. The app-facing reviewed-swap shape LeChef consumes is `contracts/substitution.schema.json` (derived from a pair, referencing it by `pairId`). The old in-code map (`SubstitutionService.swift:80–117`, 27 hardcoded pairs) is replaced by a loader over the same IDs, keeping the legacy `Substitution` view type for compatibility where the cooking guide still renders options. Integration (`SubstitutionService` → `FLSubstitutions`) is explicitly out of PR #114's scope, so the LeChef substitution slice owns it.

**Lookup.** `SubstitutionTable.options(ingredientID:role:) -> [ReviewedSwap]`, role being the ingredient's function in this recipe (one of the 11 roles) plus the eater set. A pair matches when original and role agree; an unmatched role falls back to a `supported_also` role with its own ratio; a pair whose `fails` names this role (functional or conditional-for-a-restriction-present-at-the-table) is excluded; no match → empty, and the UI offers the Live route or nothing.

**Allergen recheck, for every eater, including compound ingredients.** Every eater's explicit restrictions (PR #86 §3.3, hard filters) are checked against the substitute's **allergen closure**: the substitute's declared allergens plus the transitive allergens of its compound parts (soy sauce → wheat+soy; pesto → tree nuts+dairy; garam masala blends carry their components). The closure comes from PR #114's registry and recheck contract: `facts_key` does an exact-name match on the normalized name against the store's identities — never fuzzy — and a null `facts_key` fails closed. The registry maps 123 of 381 records; 258 fail closed to *ask-the-user* (PR #114's own semantics). LeChef's verdict rules on top:

- **Reviewed-table swap, recheck `verified|plausible`**: ships when the closure is disjoint from every eater's restrictions.
- **Reviewed-table swap, recheck `unknown`** (no canonical record): *ask the user* — offered only with an explicit per-eater "check the label" confirmation step, never silently ("composition unknown — check the label before serving to Ada").
- **Live suggestion, any recheck other than `verified|plausible`**: blocked outright — a live suggestion never triggers the ask-the-user flow ("composition unknown — can't verify: blocked for Ada"). Absence of evidence is not allergen-free.

Allergen classes are #114's nine shared classes with wheat riding on `gluten` (soy sauce carries `soy` **and** `gluten`); wheat-specific medical notes (coeliac vs wheat allergy) ride in `allergen_note`, never as a separate class; the 13 restrictions map to the FL app vocabulary (`fl.allergens`/`fl.diets`). This recheck runs for reviewed-table swaps *and* Live suggestions; Live cannot waive it, and its recheck result is computed on the phone before display.

**Copy.** Swaps describe the difference ("a little tangier, less rich") and never promise "no change" (PR #86 §3.1). The blocked state names the eater and the compound path ("Contains wheat via soy sauce — blocked for Ada").

---

## 7. Plan

**The allocation.** Input: candidate recipes (catalog + saved + rescued), their ingredient bills for the chosen revision, current pantry lots with quantities/units/expiry/confidence, eater restrictions, the already-planned set. Output: an ordered plan of 3 dinners plus a shopping list, each line carrying a state.

Algorithm (deterministic, local, <100 ms; `contracts/plan.schema.json`):

1. **Availability pool.** Build a per-ingredient pool from eligible lots (not expired, not reserved by the already-planned set). Scans observe; only receipts/manual adds create stock (PR #86 §3.2) — allocation never assumes a scan means "more than seen".
2. **Candidate scoring.** Rank by: use-soon coverage (ingredients inside use-by horizon count triple), taste fit (explicit profile only in v1), time-in-context, restriction compliance (hard filter — zero violations). Take the best feasible dinner, or the best with swaps from §6.
3. **Reserve.** Allocate that dinner's bill from the pool, FIFO by expiry (use-soon first). Reserved quantities are removed from the pool so the next dinner cannot double count the same stock — across lines, swaps, and dinners.
4. **Repeat** for dinners 2 and 3. A dinner that can't be fully covered still ships if it has ≤2 short lines; otherwise it's replaced by "pick from saved" or pushed to the shopping list.
5. **Line states.** Every line gets one of PR #86 §3.2's states: `sufficient` · `short{amount}` · `quantity_unknown` · `assumed_staple` · `needs_reconfirming` (stale evidence past its horizon). The fit line renders from states only.
6. **Shopping list** = the merge of all `short` lines after swaps, in compatible units, minus `assumed_staple` items (struck through).

**Relation to #141/#142 and #52** (all three OPEN drafts, verified 2026-10-15). None of them double counts stock within a call — #52's `WeeklyPlanConsumption.allocate` walks slots with a locally-deducted stock copy, and #141 aggregates demand once over the whole menu and rejects duplicate lots instead of double counting. What this spec adopts from them and what it adds:

- **Adopted as the allocation mechanism** — #52's canonical allocator: slots in given order, needs sorted by ingredient id (ties by grams); unknown-quantity stock never covers anything; hard exclusions are never waived even when waiving would score higher; substitution policy is primary-if-covered, else first covering substitute, else shortfall reported; `isFeasible` fails on any required shortfall. #52's exact-optimal domain (≤6 recipes × ≤3 slots) covers the default three-dinner plan; beyond it the desirability heuristic is loudly documented as non-optimal, never passed off as exact.
- **Adopted as the line-reporting shape** — #141's `GroceryLine` numbers (required / available / allocated / missing, plus `needsConfirmationGrams` and `expiresBeforeEventGrams`) render as the §line states; #142's confirm-in-the-loop is the interaction rule: confidence never confirms a quantity, explicit review converts `needsConfirmation` → `confirmed`, edits un-confirm.
- **Duplicate policy** — duplicate lots are summed at pool build (#52's tolerant aggregate, with #52's taint rule: any unconfirmed lot makes the ingredient unconfirmed); duplicate recipe IDs are rejected (#141's stricter rule).
- **What this spec adds** — reservation *across save-and-resume*: a saved plan freezes its line states and re-allocates on open, which neither PR does; and one shared core, `PlanAllocating.allocate(_:StockPool) -> Plan`, so the three surfaces (guest dinner, three-dinner plan, weekly plan) cannot drift. #141/#142's guest surface and #52's weekly flow wrap this core; their PRs adapt input assembly and presentation only. Expiry is reported as pantry truth (#141's `expiresBeforeEventGrams`), not silently excluded; fully expired lots leave the pool.

**Plan lifetime.** Saved plans freeze their line states (they are a decision record, not a live pantry view). Cooking dinner 1 consumes its lines for real and marks dinners 2–3's reserved lines as released (re-allocation on next open). A plan older than its `needs_reconfirming` horizon re-computes on open with a "recomputed — your kitchen changed" line, never silently.

---

---

## 8. The proposal / receipt contract

The backend never writes to the phone's truth. Gemini tool calls return **proposals**; the phone executes on approval and returns **receipts**. This section **adopts PR #102's pinned wire contract and re-cuts it** — the envelope `{id, tool, payload, payloadHash, snapshotRevision, createdAt, expiresAt, requiredApproval?, userInitiated?}` at `src/lechef/wire.ts:169-181` (`overhaul/lechef-f1`), re-cut by the rename map in the payload-kinds paragraph below and machine-checked by `contracts/check.py`'s round-trip of #102's frozen `action-proposal.json` fixture — rather than inventing a parallel one, and extends it in the same pattern. Schemas: `contracts/proposal.schema.json`, `contracts/receipt.schema.json`, `contracts/cook-step.schema.json`, `contracts/plan.schema.json`, `contracts/substitution.schema.json`, `contracts/scaling-rules.schema.json`. Every schema has an example fixture validated by `contracts/check.py`.

### 8.1 Proposal envelope (`ActionProposalWire`, adopted)

```json
{
  "proposalID": "prop_01J9X7Q4K2",
  "snapshotRevision": 12,
  "createdAt": "2026-10-15T18:22:31.000Z",
  "expiresAt": "2026-10-15T18:27:31.000Z",
  "payloadHash": "sha256:3ec4…",
  "kind": "swap",
  "payload": { },
  "rationale": "You're out of sour cream; Greek yoghurt is in the plan's shopping list.",
  "requiredApproval": "explicit"
}
```

Rules adapted from #102 unless noted; the envelope itself is #102's, re-cut as the map below says:

- `payloadHash` = SHA-256 over compact canonical JSON of the payload; the receipt carries it back and an approval with a mismatching hash is rejected ("payload hash mismatch"). Round-trip must be byte-identical over the Swift fixtures.
- `expiresAt` = `createdAt` + 300 s (TTL), checked **at approval time**, not just at display: expiry there yields `expired`.
- Proposals are revision-bound: a proposal built at an older snapshot revision is rejected as "superseded" at approval.
- **Timestamps canonized**: wire and fixtures are ISO-8601 ms-precision; `EpochSeconds` (integer seconds) is used only for phone-owned deadline arithmetic (`ActiveTimer.deadline`).
- `requiredApproval` and `userInitiation` are **derived audit annotations, never model-controllable inputs** — the model cannot write a claim of consent; the phone derives approval policy itself (caution adopted from #102's review history).
- **Dedupe** is call-id → payloadHash → abort checks, in that order; identical pending proposals are idempotent no-ops, resubmitting a consumed proposal id yields a rejection receipt. Session-lifetime dedupe maps are in-memory and forget on restart — **the phone's persistent receipt log (`cook_receipt`) is the dedupe authority across restarts**, not the tool layer.

**Payload kinds.** #102's registry (`src/lechef/types.ts:259-281`) registers camelCase payload kinds *inside* the payload — `timerStart` · `timerAdjust` · `stepAdvance` · `inventoryCorrection` · `mealLog` · `note` — with the six `propose*` tools as the discriminant on the wire. This spec re-cuts them: the kind is hoisted to a top-level snake_case field — `timer_start` · `timer_adjust` · `step_advance` · `inventory_correction` · `meal_log` · `save_note` (the last a rename: the phone-side kind names the persisted artifact) — `id` carries over as `proposalID` under the phone's `prop_` prefix, and the bare-hex payload hash gains the `sha256:` prefix. Two fields differ in obligation: `rationale` is our additive display-only field (#102's wire has none — the model speaks the rationale, so the schema makes it optional and #102's frozen fixture validates without it), and `requiredApproval` stays optional on the wire exactly as in #102 (its frozen fixture omits it); the phone derives it and always emits it on re-cut proposals. The round-trip is enforced, not asserted: `contracts/check.py` maps #102's frozen `action-proposal.json` through this rename map and requires the mapped envelope to validate against `contracts/proposal.schema.json`.

This spec adds the three application kinds — `plan` · `swap` · `adaptation` — named by this spec's registry (no such kind string exists in #102's corpus or `ProposalTool` union, so there is nothing to collide against), as the natural continuation of the same discriminated-union pattern (kind, revision-bound, explicit-approval), per the research recommendation. `suggest_recipe` is **not** a proposal: recipe candidates come from the `getRecipeCandidates` read tool and the model speaks them; camera look is a read tool, not a wire kind (`requestCameraLook`, device-mediated, ≤3 s clip). No kind authorizes a share or a publish — those are not proposable. The schema's `kind` enum is the enforcement.

### 8.2 Receipt (`ActionReceiptWire`, adopted)

```json
{
  "proposalID": "prop_01J9X7Q4K2",
  "payloadHash": "sha256:3ec4…",
  "snapshotRevision": 12,
  "state": "executed",
  "recordedAt": "2026-10-15T18:23:02.000Z",
  "allergenRecheck": { "verdict": "verified", "eaters": ["you", "Ada"] }
}
```

- `state` ∈ `executed` · `rejected` · `expired` · `cancelled` (#102's pinned states). `reason?` is an additive failure/detail string (e.g. `"already_resolved"`, `"superseded"`, `"payload hash mismatch"`, the blocked allergen path).
- **Apply at most once**: the proposalID is the idempotency key; a repeated confirm resolves `already_resolved` — never a second write.
- **Approval policy** (#102's `RequiredApproval`): `meal_log` is **always `explicit`** — voice alone never authorizes it; `device-auto` is possible only for timer proposals whose `userInitiation.eventId` cites a phone-recorded, unconsumed `DeviceEvent` at the current revision naming the same tool — one event initiates one action, then it is consumed. Everything else is explicit approval via `approve() → executeApproved()`; a voice transcript alone never authorizes a meal log or a share (PR #86 §4).
- `allergenRecheck` is LeChef's additive audit extension on swap/adaptation receipts (verdict from §6: `verified | plausible | unknown | unsupported` plus the eater set); it never gates the wire contract itself, which stays byte-compatible with #102.
- Receipts are written locally (`cook_receipt` audit) and sent to the gateway opportunistically; the backend summarizes them into the bounded snapshot it keeps for the session.

### 8.3 Tool registry (backend → model surface)

Adapted from #102's `runtime.ts` dispatch — 7 read tools returning `ReadToolResult<T>`, plus the 6 registered proposal tools and the 3 this spec adds:

| Tool | Kind | Returns | Notes |
| --- | --- | --- | --- |
| `getRecipeCandidates` | read | candidate recipes for the job goal | catalogue refs only |
| `getPantrySummary` | read | `PantrySnapshot` (five `PantryLineState` states, `useSoon`, expiry) | no frames, no transcript history |
| `getRecipeContext` | read | recipe context + `hasRecentCameraFrame: boolean` | model learns a frame exists, never sees one |
| `getStepContext` | read | current step, completed history, next-step short name | |
| `lookupSubstitution` | read | `SubstitutionAnswer` (reviewed table vs labelled beyond-table, `differenceNote`) | phone runs the §6 recheck before display |
| `checkFoodSafety` | read | `FoodSafetyAnswer` / `SourcedCheck` | checkable thermometer test + named source; **unknown on uncovered products** — canon loader is fail-closed, strictest-wins (`canon/food-safety/rules.json`, SHA256-gated; supersedes any embedded fsis-table evidence kind) |
| `requestCameraLook` | read (device-mediated, proposal-gated) | `CameraObservation`, `maxClipSeconds: 3` | **structurally incapable of a safety verdict**; `cameraLint` fails closed |
| `proposeTimerStart` · `proposeTimerAdjust` | proposal | `timer_start` / `timer_adjust` | device creates/adjusts; device-auto only via phone-recorded `DeviceEvent` |
| `proposeStepAdvance` | proposal | `step_advance` | explicit approval |
| `proposeInventoryCorrection` | proposal | `inventory_correction` | corrects a wrong line; never bulk-writes |
| `proposeMealLog` | proposal | `meal_log` | always `explicit` |
| `proposeSaveNote` | proposal | `save_note` | note text never leaves the phone; proposal carries only a "note saved" marker |
| `proposePlan` · `proposeSwap` · `proposeAdaptation` | proposal (spec-added) | `plan` / `swap` / `adaptation` | the phone runs §7 allocation / §6 recheck / §5 rules; the model may only shape constraints and candidates |

Unknown tool names return `{ error: 'unknown tool "…"' }` with status `"error"` (`ToolCallStatus = "ok" | "cancelled" | "duplicate" | "error"`; results carry `duplicateOf` when deduped). The three spec-added kinds are named by this spec's registry (§8.1) — no `plan`, `swap`, or `adaptation` kind string appears in #102's corpus or `ProposalTool` union — so re-cutting the suite to this registry names them with nothing to collide against.

### 8.4 Cook step shape (RECONCILE with the recipe spec)

`obv/burst5-fridgeluck-spec-recipes` did not exist when this spec was written (checked 2026-10-15 via `git ls-remote`). The recipe spec's bundle **v2 step shape** is adopted in principle; until it lands, LeChef defines the minimum in `contracts/cook-step.schema.json` and marks it **RECONCILE**:

```json
{
  "index": 3,
  "text": "Add the noodles and 3 tbsp water. Toss for 2 min until the sauce coats everything.",
  "timer": { "durationMinutes": 2, "label": "Noodles", "source": "parsed" },
  "safetyCheck": null,
  "quantities": [ { "text": "3 tbsp water", "ingredientId": null, "evidence": "household" } ],
  "equipment": ["wok"],
  "shortName": "Noodles in"
}
```

`timer.source` ∈ `parsed` (from step text) · `authored` (recipe author) · `none`. A step without a natural timer gets none — no fake timers (PR #86 §3.5). `safetyCheck` carries a checkable test when the recipe's safety data provides one (thermometer temperature + target, per PR #126's rulebook); the cook-mode renderer gives `safetyCheck` display priority over any `timer` suggestion. When the recipe spec's v2 lands, the fields are renamed/mapped there and LeChef's parser becomes an adapter over the bundle; the contracts here reconcile before the cook-integration slice ships.

---

## 9. Privacy

**Nothing about a cook outlives the cook.** The contract (PR #86 §3.4): the backend keeps no camera frames and no transcript beyond the live session; the only server-side persistence is the bounded snapshot the proposal tools read (§8.3), deleted at session end. Nothing is kept unless the user saves a note — and notes are saved **on the phone**; the backend never receives them.

**The exact `liveSessionStore.ts` change** — adopts PR #26's design and constants verbatim:

1. **Raw frames never reach Firestore.** The store's byte persistence of `latestCameraFrame` is deleted; `PersistedSessionState` omits `latestCameraFrame` entirely (PR #26's shape). Only frame metadata persists (`StoredCameraFrameMetadata`: mimeType, receivedAt, sizeBytes).
2. The gateway keeps the current frame in a **bounded in-process cache** — PR #26's `TransientFrameCache` constants: `FRAME_TTL_MS = 2 min` measured from trusted server receipt (client timestamps cannot extend retention), `FRAME_CACHE_MAX_SESSIONS = 500` with LRU eviction (`services/liveSessionGateway.ts` `recordLatestFrame` at 365 → the cache; `attachLiveSessionGateway` owns it). Cache is per backend instance and dies with the process — accepted by design.
3. `assess_live_scene` (`toolRegistry.ts:47–76`) receives the frame from the in-memory cache via `ToolDeps`, never from the store.
4. `get_recipe_context` returns `hasRecentCameraFrame: boolean` computed from the cache — the model learns a frame exists, never sees one through the store. Legacy session docs that already hold frame bytes are ignored on read and the field is deleted on the next merge write; historical remediation is owner-run (PR #26's `planning/live_session_frame_retention.md`).
5. **Session expiry, not just frame expiry.** The store gains `expireAt` = 24 h after last activity (`SESSION_TTL_MS`), refreshed on every write; reads enforce expiry (an expired record reads as blank), `ensureSession` cannot renew or restore expired records, and the gateway calls `deleteSession` on close. A session doc surviving beyond 24 h is a bug (assertion in tests). The Firestore TTL policy on `expireAt` (`gcloud firestore fields ttls update expireAt`) is owner-run and is *not* the access-control boundary — expiry enforcement in reads is.
6. The phone sends the **bounded snapshot** (`getPantrySummary`/`getStepContext`) once per session; the store's `confirmedIngredients` is trimmed to ids + coarse quantity text, never the pantry. Client authority is stripped at the protocol layer (PR #39): client `tool_response` frames are rejected, `latestConfidence` is rejected (the exact-mode confidence gate is computed server-side only), and session ids are minted server-side — a client-supplied session id is logged as ignored.

**On the phone**, everything lives in GRDB (`cook_*` tables, §11) and backs up with the user's device — that is the "unless the user saves a note" clause, kept local by default. Sharing stays a separate, previewed action (PR #86 §3.4).

---

---

## 10. Evaluation and cost

**Scripted-session suite.** A session is a script: an ordered list of turns `{who: user|fake_model|device, utterance?, action?}` plus the phone state to seed (pantry fixture, eater set, recipe). The suite covers **jobs × situations** as a matrix — five jobs × at minimum: offline, mic denied, Live disconnect mid-job, app kill + relaunch, empty kitchen, allergen conflict, partial recipe data (string steps), expired proposal, stale revision. One script per cell where the cell is meaningful; **155+ scripts** adopted from PR #101's harness where its fixtures fit the contract here (see §14).

**Scoring.** Deterministic assertions, not vibes:

- *safety*: zero recipes suggested against an eater's restriction; every meat/fish/egg step carries a thermometer check; no camera answer contains a doneness verdict (regex over transcript);
- *pantry truth*: allocation receipts match the §7 algorithm's expected line states on frozen fixtures (exact-match, no double counting — pool conservation asserted);
- *task success*: the scripted outcome (timer created on device, swap applied with passed recheck, receipt status correct);
- *conversation*: the LeChef line ≤1 sentence, ≤2 answers; five-word vocabulary never leaks into a model call;
- *cost*: frames sent per cook, connected minutes, tool calls per job — counted, compared against the cap (below), not a pass/fail until Sam sets the budget.

**Fake model, fake phone.** The fake model is a scripted responder implementing the §8 tool protocol (given state, returns the next proposal or utterance) — deterministic, no network. The fake phone is an in-memory executor of the phone-side contract (revision check, allergen recheck, timer creation) so the backend's tools can be tested without a device. Both are adopted from PR #102's harness (§14) and live under `backend/gemini-agent/src/evaluation/`.

**No paid calls in tests.** `bun test` runs fakes only. A real Gemini run is opt-in behind `LECHEF_REAL_MODEL=1` plus a spend cap env (`LECHEF_SPEND_CAP_USD`, default 0 = refused); the harness refuses to run without both, prints the cap and stops on it. CI never sets either.

**Camera candidates.** Push-to-look vs continuous is scored on the same suite: job success, frames sent, cost per cook, and on-device heat/battery measured on a real phone where possible, labelled UNVERIFIED-NATIVE otherwise (PR #86 §4).

---

## 11. Local schema through `CookSessionMigrations`

New file `apps/ios/Platform/Persistence/Database/Subsystems/CookSessionMigrations.swift` (the `Subsystems/` directory is created by the first thread that lands one; no thread edits `Migrations.swift`). All identifiers prefixed `cook_`. Tables:

| Table | Columns (type) | Notes |
| --- | --- | --- |
| `cook_session` | `id` TEXT pk (`sess_…`), `recipe_ref` JSON (RecipeRef), `servings` INTEGER, `eater_ids` JSON array, `state` TEXT (`cooking`/`remembering`/`remembered`/`abandoned`), `current_step` INTEGER, `completed_steps` JSON array, `started_at` TEXT ISO-8601, `ended_at` TEXT NULL, `revision` INTEGER ≥1 (bumped per write), `rating` INTEGER NULL 1–5 | one active session at a time (partial index on `state='cooking'`) |
| `cook_timer` | `id` TEXT pk, `session_id` TEXT fk, `label` TEXT, `deadline` TEXT ISO-8601 (absolute), `paused_at` TEXT NULL, `remaining_when_paused_seconds` REAL NULL, `fired_at` TEXT NULL | durability per §4.2; notification id = timer id |
| `cook_adaptation` | `id` INTEGER pk auto, `session_id` fk, `at` TEXT, `kind` TEXT (`servings`/`quantity`/`equipment`), `input` JSON, `applied` JSON, `caption` TEXT | the remember receipt reads these |
| `cook_substitution` | `id` INTEGER pk auto, `session_id` NULL fk, `plan_id` NULL fk, `original_id` INTEGER (ingredients.id), `substitute_id` INTEGER, `ratio` REAL, `note` TEXT, `allergen_recheck` JSON, `source` TEXT (`table`/`live`/`manual`) | plan-level swaps use `plan_id` |
| `cook_receipt` | `proposal_id` TEXT pk, `session_id` fk, `status` TEXT, `decided_at` TEXT, `decided_by` TEXT, `applied` JSON NULL, `failure` JSON NULL, `session_revision` INTEGER | §8.2 audit |
| `cook_remember` | `session_id` pk fk, `rating` INTEGER NULL, `note` TEXT NULL, `saved_at` TEXT, `skipped` INTEGER 0/1 | the saved note; never synced |
| `cook_plan` | `id` TEXT pk (`plan_…`), `created_at` TEXT, `horizon_dinners` INTEGER, `state` TEXT (`draft`/`saved`/`superseded`), `fit_summary` JSON | |
| `cook_plan_dinner` | `id` TEXT pk, `plan_id` fk, `position` INTEGER 1–3, `recipe_ref` JSON, `servings` INTEGER, `state` TEXT (`planned`/`cooked`/`skipped`), `cooked_session_id` TEXT NULL | |
| `cook_plan_line` | `id` TEXT pk, `dinner_id` fk, `ingredient_id` INTEGER, `required_quantity` JSON NULL, `line_state` TEXT (`sufficient`/`short`/`quantity_unknown`/`assumed_staple`/`needs_reconfirming`), `short_quantity` JSON NULL, `swap_substitution_id` TEXT NULL | frozen at save per §7 |

Migrations are additive, one `migrator.append` per version, run by `AppDatabase`. The plan tables hold *frozen decisions*; the live pantry remains owned by the inventory subsystem — allocation reads it, never writes it.

---

## 12. Mocks in words

§3 is the mock set: each surface there carries purpose, intent-based entry points, top-to-bottom layout with exact copy, every state, data effects of each interaction, and accessibility — including cook mode's hands-busy needs (64 pt targets, step text readable at arm's length, mono-highlighted quantities, voice row with honest states). The visual reference is `mocks/cook-lechef.html` on `docs/spec-overhaul-20261011` (Direction F, hob palette); this spec's decisions override it where noted (D3, §3.1 partial-data state, §3.3 unreviewed-suggestions strip).

---

## 13. Events for the taste spec

Emitted as `TasteEvent` (`surface` ∈ `cook_mode` · `plan_sheet` · `swap_sheet` · `rescue` · `remember_receipt` · `chat`), kinds proposed here — `docs/spec/taste/` owns the final registry and payloads:

| kind | when | payload (proposed) |
| --- | --- | --- |
| `lechef.cook_started` | session start | `{recipe, servings, eaterCount}` |
| `lechef.step_completed` | each completed step | `{recipe, stepIndex, viaTouch}` |
| `lechef.timer_fired` | timer reached deadline | `{recipe, label, acknowledgedBy}` |
| `lechef.swap_proposed` · `lechef.swap_accepted` · `lechef.swap_rejected` | §3.3 | `{original, substitute, source, necessary: null\|bool}` |
| `lechef.adapt_applied` | §5 | `{recipe, kind, from, to}` |
| `lechef.plan_proposed` · `lechef.plan_saved` | §3.2 | `{dinners: [RecipeRef], fitSummary}` |
| `lechef.rescue_opened` · `lechef.rescue_cooked` | §3.4 | `{items: [IngredientID]}` |
| `lechef.remember_saved` · `lechef.remember_skipped` | §3.5 | `{rating: null\|1-5, hasNote}` |
| `lechef.voice_used` | five-word intent fired by voice | `{command}` |

No event carries a note's text, a photo, or health data. Ratings and swaps only, per PR #86 §3.4's aggregate-fields rule.

---

## 14. The drafts — adopt, adapt, reject

*(Summaries; the research notes behind each live in the fleet thread's research files.)*

| Draft | Verdict | What and why |
| --- | --- | --- |
| **#102** TS tool layer (proposals/receipts, fake phone + fake model) | **Adopt** | The proposal/receipt wire contract and the fakes are the backbone of §8 and §10. Adapt: its tool names and payload branches are re-cut to the kinds in §8.1 — `note` renamed `save_note`, the kind discriminant hoisted from the payload to the envelope, the bare-hex hash `sha256:`-prefixed, `rationale` added as a display field — `mutate_inventory` removed rather than wrapped, and the fake phone gains the allergen recheck; the re-cut is machine-checked by `contracts/check.py`'s round-trip of #102's frozen `action-proposal.json` fixture. |
| **#101** 155 scripted sessions + scorer | **Adopt** | Suite size and scorer dimensions feed §10 directly. Adapt: scripts re-written against this spec's contract fixtures; safety and pantry-truth assertions added as pass/fail gates. |
| **#83** cooking checkpoints | **Adapt** | Checkpoints map to `safetyCheck` on the step shape (§8.4) and to the "check, don't trust the timer" captions (§5) — not a separate state machine, which would duplicate the §4 session states. |
| **#28** clean cook steps | **Adopt** | Step splitting at timer/action boundaries is exactly §8.4's `timer.source: parsed`; adopted as the parser spec, marked RECONCILE with the recipe bundle. |
| **#141 / #142** guest planner (on main) | **Adapt** | Kept as a surface over the §7 core for "one dinner, N eaters"; its own allocation is retired wherever it double counts stock (§7). |
| **#52** weekly plan | **Adapt** | Same core across seven slots with a repeat penalty and leftover carry (§7); not a second planner. |
| **#114** reviewed substitution table | **Adopt** | Ships in the bundle (§6); the legacy in-code map is replaced by the loader. Adapt: entries surface to the app as role-scoped reviewed swaps derived from #114's `pairs.json` (schema 1.1.0: 279 pairs, 381 ingredients, 11 roles, 13 restrictions), rechecked fail-closed via exact `facts_key` match. |
| **#39 / #26** backend authority, frame persistence | **Adopt** | Phone-authoritative with proposals/receipts (§8) and the frame-persistence fix (§9) are these drafts' direction, tightened: frames in process memory only, session TTL, bounded snapshot. |

The contract pack under `contracts/` is machine-checked, not aspirational: `contracts/check.py` validates the six schemas and eight fixtures (schema validation plus TTL, payload-hash round-trip, plan pool conservation, and nine-class allergen cross-checks) — `python3 contracts/check.py` must pass before any slice above is called done.

---

## 15. Implementation slices

Six slices, exactly these packet ids. Later threads start from them without asking anyone.

**`burst5-fridgeluck-lechef-cook-core`**
- Owns: `apps/ios/FeatureLogic/CookMode/` (new): `CookSessionMachine.swift`, `CookTimerStore.swift`, `VoiceCommandParser.swift`, `ScalingEngine.swift`, `ScalingRules.swift`; `Platform/Persistence/Database/Subsystems/CookSessionMigrations.swift` (§11 tables).
- Public types: `CookSessionMachine` (`start`, `advance`, `back`, `repeat`, `complete`, `abandon`, `state: CookSessionState`), `CookTimerStore` (`create`, `pause`, `resume`, `remove`, `active`, `pendingFired`), `VoiceCommandParser.parse(String) -> CookVoiceIntent?`, `ScalingEngine.scale(_:Servings, Evidence) -> [ScaledLine]`.
- Tests: state-machine transitions incl. kill/relaunch, timer deadline math across clock changes, parser grammar table (numbers, fractions, synonyms), scaling rules (to-taste, sub-linear, count-hold).
- Done-when: `swift test` (portable core) passes on Linux; all §10 safety and pantry assertions for the cook job pass with the fake phone; `cook_*` migrations apply on a fresh DB and on a copy of the shipped store.

**`burst5-fridgeluck-lechef-plan`**
- Owns: `apps/ios/FeatureLogic/CookMode/Plan/`: `PlanAllocating.swift`, `StockPool.swift`, `PlanDataAdapter.swift`, `PlanSheetViewModel.swift`; plan tables in `CookSessionMigrations.swift`.
- Public types: `PlanAllocating.allocate(_:StockPool) -> Plan` (deterministic), `StockPool(lots:reservations:)`, `PlanDataAdapter` (reads inventory read-only, writes `cook_plan*`).
- Tests: pool conservation (no double counting across dinners/swaps), line-state matrix on frozen fixtures, use-soon ranking, re-allocation after cooking dinner 1.
- Done-when: allocation matches expected outputs on the frozen fixture set; the fit line renders only from line states; plan save/persist round-trips.

**`burst5-fridgeluck-lechef-substitutions`**
- Owns: `apps/ios/Capability/Core/Substitutions/`: `SubstitutionTable.swift`, `AllergenRecheck.swift`, bundle resource `Substitutions.json` (+ loader).
- Public types: `SubstitutionTable.options(ingredientID:context:) -> [ReviewedSwap]`, `AllergenRecheck.check(substituteID:eaters:) -> RecheckResult` (fail-closed).
- Tests: compound-ingredient closure (soy sauce → wheat), unknown-composition blocks, eater union, table lookup contexts, legacy map parity.
- Done-when: every shipped entry validates against `contracts/substitution.schema.json`; recheck passes the §10 allergen scripts; the old `SubstitutionService` is a thin wrapper or gone.

**`burst5-fridgeluck-lechef-tools`**
- Owns: `backend/gemini-agent/src/agent/` proposal tools, `src/contracts/` (TS mirrors of §8), `src/evaluation/` (scripted suite, scorer, fake model, fake phone).
- Public types: `Proposal`, `Receipt`, tool handlers per §8.3, `FakeModel`, `FakePhone`, `runSuite(scripts) -> ScoreReport`.
- Tests: schema validation of every fixture (ports `contracts/check.py` expectations), fake-phone revision/expiry rejection, scorer gates (safety/pantry), spend-cap refusal without env flags.
- Done-when: `npm run check` and `bun test src/__tests__` pass with zero network; §10 suite green on ≥155 scripts; `mutate_inventory` gone from the registry.

**`burst5-fridgeluck-lechef-cook-integration`**
- Owns: `apps/ios/Feature/CookMode/` (views: `CookModeView`, `TimerTile`, `RememberSheet`), `apps/ios/Feature/Plan/PlanSheet.swift`, `SwapSheet.swift`, rescue card; phone-side `ProposalExecutor.swift` (`Capability/Assistant/`); entry points wired into the existing cook flow (`CookingGuideView` keeps working, cook mode is the new path).
- Public types: `ProposalExecutor.execute(Proposal) -> Receipt` (revision + allergen + touch rules), view models per surface.
- Tests: portable view-state tests (states of §3.1), executor rules (voice-confirmed kinds, expiry), receipt write-through.
- Done-when: §3 surfaces render all states from view-state values; macOS CI compiles the app target (UNVERIFIED-NATIVE otherwise, stated); a scripted end-to-end cook (start → timer → swap → complete → remember) passes against the fake model.

**`burst5-fridgeluck-lechef-live-wiring`**
- Owns: `backend/gemini-agent/src/services/liveSessionGateway.ts` (tools bound to proposals, in-memory frames, `deleteSession` + TTL sweep), `src/session/liveSessionStore.ts` (§9 changes), `apps/ios/Integration/GeminiLive/` (bounded snapshot upload, push-to-look capture, local voice fallback).
- Public types: `InMemoryFrameHolder`, `SessionLifecycle` (close/TTL), `BoundedSnapshotBuilder`, `PushToLookController`.
- Tests: frame never persists (store contract test), TTL sweep deletes stale docs, snapshot contents bounded, five-word parser fires offline, spend-cap counting per session.
- Done-when: the §9 store change ships with tests asserting no `latestCameraFrame` in any persisted doc; suite runs the live-job scripts green; connected-minutes and frame counts reported per cook.

**Ordering.** cook-core → cook-integration needs plan + substitutions for the full sheet set; tools is independent (backend) until live-wiring binds them. live-wiring last: it consumes everything.

---

## 16. Open decisions for Sam (work proceeds on the defaults)

1. **Cook-mode camera**: push-to-look (default, §D3) vs continuous — decided by the §10 scoring round; heat/battery numbers need a real phone.
2. **LeChef cost budget**: none exists; voice stays opt-in per cook and "Just the steps" is the default until Sam sets a monthly cost per active cook (PR #86 §4).
3. **Step shape ownership**: LeChef's minimum `cook-step` (§8.4) vs the recipe spec's bundle v2 — default: recipe spec wins, LeChef adapts before cook-integration ships.
4. **Substitution corpus source**: PR #114's table is the seed; how many entries and who reviews additions is the recipe-platform thread's call.
5. **Plan horizon**: three dinners is the default; #52's weekly surface may want 5–7 with the same allocator.
6. **Allergen unknowns**: fail-closed (§6) blocks swaps whose composition is unknown; Sam may prefer "warn, allow" for non-declared-severity cases.

---

## 17. Requirement traceability

| Task item | Where |
| --- | --- |
| 1 surfaces | §3 |
| 2 jobs × local core | §2 |
| 3 state machine, timers, voice | §4 |
| 4 adapt | §5 |
| 5 substitutions | §6 |
| 6 plan allocation | §7 |
| 7 proposal/receipt, tools, step shape | §8 |
| 8 privacy | §9 |
| 9 evaluation and cost | §10 |
| 10 local schema | §11 |
| 11 mocks in words | §3, §12 |
| 12 events | §13 |
| 13 slices | §15 |
| drafts | §14 |
| open decisions | §16 |
