# Coach — LeChef voice-DESIGN configuration

Design id: `coach` · branch `overhaul/lechef-design-coach` · built on `overhaul/lechef-f1` at `a01cc1c`.

The coach competes against the planner (batch up-front) and a third direction (suite C) on the
shared offline layer: `LeChefDesign` config + `gateScript`/`runDesignSession` in
`src/lechef/run/designRunner.ts`, all scripts replayed offline on the fake phone and fake model
(`fakePhone.ts`, `fakeModel.ts`). Nothing here touches the shared layer; everything is inside
`src/lechef/designs/coach/` and its test mirror `src/__tests__/lechef/designs/coach/`.

## Thesis

Cooking has exactly one moment that cannot be paused: the pan is hot now. The coach optimizes
for that moment. It speaks only about the step the user is on, it interjects at most twice per
session and never in bursts, it grounds every suggestion in a read of real pantry or food-safety
state, and it goes quiet about a topic the user has refused twice.

Three bets make this different from the other designs:

1. **Reads proactively, acts on ask.** The coach spends its unprompted turns on information
   (pantry state, FSIS-sourced doneness temps, step context) — never on phone mutations. Reads
   are invisible and cheap; actions need an ask. This splits the proposal layer along the
   read/write line instead of along the proactive/reactive line.
2. **A tight speech budget is a feature, not a handicap.** `maxUnpromptedTurns: 2`,
   `minGapTurns: 2`. If the coach only has two things to say all session, they have to be the
   two best things: a use-soon item that is about to matter for this recipe, and a safety
   reminder at the safety-critical step. Everything else waits for a prompt.
3. **Silence is scoped to a topic, not to the coach.** After two rejections of a suggestion
   type (`use-soon`, `safety`, `substitution`), that type is silent for the session. Safety
   never inherits use-soon's rejections — the spec's silence rule protects against nagging, not
   against an undercooked chicken.

## The knobs, each with its rationale

### `turnBudget: { maxUnpromptedTurns: 2, minGapTurns: 2 }`

The strictest budget of the three designs. Rationale from the spec's product direction: the
user mid-cook is head-down and hands-wet; every unprompted utterance costs attention exactly
when attention is scarcest. Two is enough for the coach's two signature moves (safety nudge +
use-soon nudge); the min-gap of two emitted turns guarantees the coach never machine-guns two
interjections without the user speaking in between (fixture `coach-009-min-gap`), and it also
keeps the second interjection from riding on the heels of the first in a quiet session.

Observed trade-off (replay `coach-008-budget-exhausted`): the third interjection dies even when
it is cleanly gapped and non-rejected. That is the intended spend — the budget buys "never
talks over you" at the price of completeness.

### `toolPolicy` (ordered deny rules, first match wins)

| # | match | decision | reason | why |
|---|-------|----------|--------|-----|
| 1 | proactive `proposeMealLog` | deny | `coach-proposal-meal-log` | Meal logging belongs to Remember's end-of-meal flow, not to mid-cook chatter. Even a *prompted* coach mid-sauté shouldn't open a remember flow; the runner's `approvalFor` classifies `proposeMealLog` as always-explicit, and the coach denies it in every context. |
| 2 | proactive proposal (`proposeStepAdvance`, `proposeTimerStart`) | deny | `coach-proposal-ask-first` | See the justification below. |
| 3 | proactive `requestCameraLook` | deny | `coach-camera-push-to-look` | The script fixtures set `cameraMode: "push-to-look"`. The spec: camera looks never yield safety verdicts (`ReplayCameraEvent.safetyVerdict` is structurally `null`). An unprompted "let me glance" reads as surveillance and burns budget; a user-invoked look is evidence on request. Fixture `coach-005-camera-push-to-look` shows both sides. |

Everything not denied passes: proactive `getPantrySummary`, `checkFoodSafety`,
`getStepContext` (`coach-001`, `coach-002`) and all prompted tools. The read/write split is the
whole policy — five lines instead of an allow-list matrix.

**Why the coach does not get proactive step-advance even though step advance is its job focus.**
The direction asked me to justify any proactive allowance against the "proposals need an ask"
principle. I land on *no allowance*, for three reasons. First, the shared layer already decided:
`approvalFor` classifies `proposeStepAdvance` as **always-explicit** — a proactive call would
still strand the user on a confirmation dialog they never asked for, so the "allowance" buys
nothing but friction. Second, the phone UI has its own step-advance affordance; a voice-side
proactive advance risks a double-advance race the offline layer cannot arbitrate. Third, the
competitive space needs the contrast: the planner owns proactive batched proposals, so the
coach's identity is "the assistant that nudges but never acts unprompted." The coach still
*coaches the advance* — its proactive turn can say "when you're ready, say 'next'" — it just
doesn't call the tool until asked.

### `suggestionType` — `use-soon | safety | substitution`

Suggestion kinds, used only by the third-rejection-silence gate. Prefix convention in fixtures:
a suggestion turn starts with `use-soon:`, `safety:` or `substitution:` (runner text includes
the prefix; the fixtures use it consistently so classification is stable in JSON-authored
scripts too). Classification is `coachSuggestionType` in `design.ts`, exported so the replay
runner and the tests classify identically. A turn that is none of these classifies as `null`
and never accrues or consumes silence.

Silence semantics: **two rejections of one type → that type is silent for the session**. What
counts as a rejection (`isRejection`) is deliberately narrow: a short no-ish opener ("no",
"nah", "not interested", "stop", "skip it", …) **directly after a kept suggestion of that
type**. A question ("how long do I have on it?") or a normal instruction between suggestions
never accrues (`coach-007-rejection-attribution` pins this: the non-rejection resets
attribution, so the third attempt is silenced only by the two real rejections). The runner
pins `isNoise` (barge-in kills) and does the kill path itself; `isRejection` is the coach's
complement — it classifies silence-worthy rejections, not interruptions.

### `systemPrompt` (documented-for-future-wiring)

The offline replay does not consume the prompt; it is the design's intent statement for future
live wiring: one- breath answers; thermometer over color; never a camera verdict; reads pantry
and safety data unprompted but acts only on request; two unprompted interjections per session,
never adjacent; a refused topic goes quiet for the session.

## Design-local cores: not needed

The brief allows `designs/coach/cores/` for behavior the shared fake model cannot express.
Studied `fakeModel.ts` and `run/harness.ts` first: the fake model replays scripted turns
verbatim, and everything distinctive about the coach — policy denials, budget/min-gap
suppression, rejection silence — happens in `gateScript`/`runDesignSession` driven purely by
the config in `design.ts`. A local core would add a second behavioral path with no offline
effect, so there is none; the directory is intentionally absent.

## What the replay shows

`bun run src/lechef/designs/coach/run.ts` — 12 scripts, exit 0, all expectations met:

| script | focus | outcome |
|---|---|---|
| coach-001-proactive-safety-read | proactive `checkFoodSafety` + `getStepContext` at a safety-check step | both pass; doneness answer cites 74 °C from the sourced check |
| coach-002-proactive-pantry-use-soon | proactive `getPantrySummary` grounds a use-soon suggestion | passes; suggestion is grounded in real pantry state |
| coach-003-proactive-proposals-denied | proactive advance + timer + meal-log + a read in one turn | proposals denied with `coach-proposal-ask-first` / `coach-proposal-meal-log`; the read passes; nothing reaches the phone |
| coach-004-prompted-proposals-approved | prompted advance and timer | advance explicit → executed after phone approval; timer device-auto (direct user command) |
| coach-005-camera-push-to-look | proactive vs requested camera look | proactive denied `coach-camera-push-to-look`; requested look records 2 frames, verdict structurally null |
| coach-006-use-soon-silence | third use-soon after two rejections | turn 4 `suggestion-type-silenced`; the later safety suggestion still flows |
| coach-007-rejection-attribution | a question between suggestions | non-rejection never accrues; only the two real rejections silence the third attempt |
| coach-008-budget-exhausted | third cleanly-gapped interjection | `budget-exhausted` after two kept unprompted turns |
| coach-009-min-gap | adjacent unprompted turns | second interjection `min-gap`; after a user exchange the coach may interject again (budget not consumed by suppression) |
| coach-010-suppressed-action-remap | kill + clock advance on suppressed turns | actions remap to the next kept turn, nothing drops |
| coach-011-prompted-only-control | all-prompted session | zero suppression, zero denials — record identical to the plain harness (see equivalence) |
| coach-012-substitution-beyond-table | substitution suggestions with an absent lookup table | lookup passes as an explicit beyond-table unknown; the type silences on its own rejections |

Usage is fully accounted per script (tokens in/out, audio seconds, camera frames, connected
seconds) — cost is measured, as the spec requires.

## Equivalence

`equivalence.test.ts` proves the design layer adds behavior without changing the harness:

- A **permissive variant** (`coachPermissiveVariant`: empty policy, unbounded budget, same
  suggestion semantics) reproduces the plain `runSession` record for the prompted-only control
  exactly (modulo the record's `design` field).
- The **strict coach design** does the same on that script — an all-prompted session never
  trips any gate.
- On a proactive script the permissive variant and the coach design diverge exactly as
  intended: the coach's proposals never reach the phone, the permissive ones do. The delta is
  the policy, nothing else.

## Verification

Run from `backend/gemini-agent` (offline; no Gemini, no network):

```
bun run check                                   # tsc, clean
bun test src/__tests__                          # 409 pass, 0 fail (394 baseline + 15 coach)
bun run src/lechef/designs/coach/run.ts         # 12/12 scripts match; exit 0
```

The 15 coach tests cover policy denials (with typed reasons), budget + min-gap + remapping,
per-type silence + attribution + session scoping, and the three equivalence checks.

## Limitations

- **The runner is phase-blind.** The budget counts emitted unprompted turns, not cooking
  phases; the coach cannot prefer the sear phase over the plate-up. Session state
  (step advancement) does not modulate gating yet — an explicit follow-up for whichever design
  wins.
- **`isRejection` is lexical.** "nah" is a rejection; "no way that's already done?" is not —
  but the regex only sees the opener, so a question that *starts* with a no-ish token could
  mis-acquire. The fixtures pin the intended cases; a live design needs intent classification.
- **Silence is session-scoped and per-type, not global.** The spec leaves the shape open; the
  coach picks per-type (safety never inherits use-soon rejections) and never across sessions.
- **Substitution knowledge is beyond this design's table.** `lookupSubstitution` on alpha
  reports unknowns (fixture `coach-012` exercises exactly that); reviewed tables land elsewhere.
- **The system prompt is unwired.** It documents intent; the offline replay can't score prose.

## Open questions

1. Should a *safety* suggestion ever be exempt from silence entirely? Current answer: no —
   safety suggestions are rare enough that two rejections ending them is still correct; the
   safety *read* (`checkFoodSafety`) stays available on ask either way.
2. Should the budget reset when the recipe's step changes? A session-long budget of 2 is
   strict for long recipes; a per-phase budget needs runner support (shared-layer change —
   reported, not made).
3. Is `substitution` a coach suggestion or a planner carry-over? The coach uses it reactively
   here ("I'm out of X"); a design that proactively suggests substitutions would need its own
   budget slot.

## Shared-layer changes wanted but not made

None required. Everything above is expressible in the existing `LeChefDesign` contract. The
per-phase budget (open question 2) would need a runner change and is reported here instead.
