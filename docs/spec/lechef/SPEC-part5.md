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
