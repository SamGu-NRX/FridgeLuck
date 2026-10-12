# Planner — design notes

Design config: `design.ts` · Scripts: `scripts/` · Replay: `run.ts` (`bun run src/lechef/designs/planner/run.ts` from `backend/gemini-agent`) · Tests: `src/__tests__/lechef/designs/planner/`

## Thesis

LeChef earns its keep **before and after the cook**, not during it. The failure mode this design optimizes against is mid-cook chatter: an assistant that narrates between steps, offers unsolicited adjustments, and trains the household to treat it as noise. The planner spends its whole proactive allowance in one **batched opening plan** — what to cook, in what order, which timers — then goes quiet until spoken to, then does one strong **remember step** at the natural closing point (the meal log).

Jobs owned: **plan** + **remember**. Coach/adapt/substitute are other designs' lanes; this design only promises not to get in their way (short prompted answers, no unprompted writes).

## Knob choices (design.ts)

| Knob | Value | Why |
|---|---|---|
| `turnBudget.maxUnpromptedTurns` | `3` | Exactly the opening batch: one turn to pitch the pick (+1 alternative), one to propose its timers, one to close the open (order, shopping list). Three is the smallest number that fits the batch; anything more invites mid-cook drift. |
| `turnBudget.minGapTurns` | `0` | The batch is three adjacent unprompted turns. Any positive gap suppresses every adjacent proactive turn (the runner suppresses when `turnsSinceUnprompted < minGapTurns`), which would make the signature move impossible. This is the only value that expresses "batch". |
| `toolPolicy` | One rule: `proposeTimerAdjust`, `proposeStepAdvance`, `proposeInventoryCorrection`, `proposeSaveNote`, `proposeMealLog` denied `proactive` | The planner's ONLY unprompted proposals are the timers that belong to the opening plan batch. Every other write waits for a prompt — the user's words call for it, not the assistant's clock. Reads are never listed (the open is read-heavy by design); `proposeTimerStart` is never listed (the up-front timer proposals are the thesis). The denial is a typed `{ error: "policy-denied", deniedBy: "planner", reason }` at the dispatch boundary — visible in the record, never silent. |
| `suggestionType` | `plannerSuggestionType`: `plan-pitch` / `timer-offer` / `meal-log-offer` | Silence (SPEC 4) scopes per suggestion type. These three are exactly the planner's unprompted offer vocabulary. A meal-log offer is also recognizable from the `proposeMealLog` call it carries, so the matcher works even when the copy doesn't start with the tag. |
| `isRejection` | Contract default (kept) | The default counts explicit no-ish openers ("no", "not interested", "stop") and does not count "something else" — the product direction classifies that as a weak, ambiguous signal. Tightening further would under-count real refusals; loosening would punish ambiguity with silence. |
| `systemPrompt` | Documented-for-future-wiring | The offline replay does not consume it (gate + replay run on budget, deny-list, suggestion typing). It is written as the production prompt: batch the open, silence mid-cook, one log offer at close, timers live on the device, camera looks never give safety verdicts. |

### What the contract cannot express (explicit)

The contract's `TurnBudget` is **session-wide**; it cannot bind the allowance to a phase. "Higher budget for the opening phase, near-zero mid-cook" is therefore only approximated: the budget is 3 and the *intended* spend is turn 0–2, but a session whose user speaks first and never opens with the batch can spend all three turns mid-cook (`plan-user-driven-budget-stress` pins exactly this leak). The script shape and the documented system prompt carry phase discipline beyond that; the budget alone cannot. Expressing true phase-awareness would need either (a) a `phaseHint` on `ScriptTurn` the budget can read, or (b) a per-phase budget map (`{opening, cooking, closing}`) in `LeChefDesign` — both shared-layer contract changes, out of this task's ownership. Nothing here was hacked around it.

`cores/` was **not needed**: every behavior this design probes (budget suppression, typed silence, policy denial, proposal dedupe, device timers across kill/resume) is expressible with the shared fake model + fixture scripts. Deterministic offline replay required no design-local cores.

## What the replay shows

`bun run src/lechef/designs/planner/run.ts` — 12 scripts, 12/12 matching expected shape, exit 0.

- **Opening batch survives** (`plan-open-batch-kept`): pitch + two timer proposals land unprompted; a proactive `proposeSaveNote` inside the same open is policy-denied with the exact typed result while its prompted twin passes.
- **Mid-cook silence** (`plan-open-batch-then-midcook-suppressed`): the open spends the whole budget; the mid-cook unprompted timer adjust is suppressed (`budget-exhausted`); the prompted retry executes and the simmer really drops to 10 minutes.
- **The leak is pinned, not hidden** (`plan-user-driven-budget-stress`): with no opening batch, three unprompted turns land mid-cook before the wall — the documented cost of a session-wide budget.
- **Silence is typed and scoped** (`plan-pitch-rejection-silence`, `timer-offer-silence-scoped`, `remember-meallog-silence-after-two`): two rejections of a type silence the third offer of that type only; the plan type still speaks while the timer type is dead. Rejections accrue only to suggestions the design actually emitted — a suppressed suggestion cannot be rejected into more silence.
- **Remember step** (`remember-close-meallog-*`): the closing log offer is prompted, explicit-approval, and executes on the tap; the unprompted variant is denied at the dispatch boundary. `proposeMealLog` is hard-coded explicit in the shared `approvalFor` and this design's policy keeps it that way — the config never attempts to relax it.
- **Timers are device-owned** (`plan-timers-survive-kill`): an opening-batch timer approved at 18:05 survives kill + resume and fires at its absolute 18:14 deadline (SPEC 4). `plan-timer-approval-modes`: a dictated timer replays `userInitiated` → `device-auto` (executes at submit); a model-proposed timer is `explicit` and waits.
- **Reads are free** (`plan-read-burst`): a proactive read-heavy open — four reads, zero denials. The deny-list is write-shaped by construction.

Usage stays modest across the suite (e.g. the opening batch session: 7 turns, ~12 tok text in, ~68 tok out, 0 frames — the open is text-only and camera-free by design).

## Equivalence check

`equivalence.test.ts`: a permissive variant of the planner (unlimited budget, only the safety-critical camera deny-list retained) reproduces the **plain harness record** for the prompted-only control script — identical record body except the design stamp. The strict planner does the same on that script (no proactive turns → no gate effect), so the design's entire observable footprint is exactly what its knobs claim it is.

## Limitations

- **Phase-blind budget** — see "What the contract cannot express". The leak is pinned by test, not fixed.
- **Suggestion typing is a text convention** in scripts (`"Plan:"` / `"Timer offer:"` / `"Log offer:"` prefixes) plus the meal-log tool-call signal. Native wiring classifies structured model output instead; the matcher contract (`ScriptTurn → type | null`) is identical, so the scripts port.
- **The system prompt is not exercised offline** — the replay consumes budget/policy/suggestions only. Prompt quality (does the model actually batch?) is a live-model evaluation question; the offline layer pins what the *policy* does regardless of what the model says.
- **Script count is deliberately 12 focused probes** — not a corpus. The general plan/substitute/coach/adapt/remember corpus belongs to suite D.

## Open questions

1. **Phase-aware budgets** (above): would the parent accept a per-phase budget map in `LeChefDesign`, or should phase discipline stay prompt-side? This design works either way, but the mid-cook leak is real and only contract surgery closes it.
2. **Rejection accrual across a budget wall**: a budget-suppressed suggestion cannot be rejected (rejections accrue only to emitted suggestions), but a *prompted* re-pitch of the same idea still accrues rejections — correct, but worth a scorer note.
3. **Silence scope lifetime**: per session (current, shared-layer semantics). The planner's remember step would prefer a per-*meal* scope across sessions; that is a shared-layer semantics question, not a knob.
