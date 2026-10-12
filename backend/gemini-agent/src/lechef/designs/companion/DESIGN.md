# Companion design — LeChef voice presence for solo cooking

Design id: `companion`. Owned directory: `src/lechef/designs/companion/` (built on the
shared layer in `src/lechef/` at `a01cc1c`; see `../../README.md` for the contract this
consumes). This document covers the thesis, every knob with its rationale, what the
offline replay demonstrates, limitations, and open questions.

## 1. Thesis

Cooking alone is the loneliest household activity in FridgeLuck's audience. The
competitor designs optimize elsewhere — one for planning throughput, one for
instructional precision — and the companion optimizes for **warm, brief presence**: it
answers like a friend leaning in the doorway, not a sous-chef holding a clipboard. Four
commitments follow from that thesis, and every knob below is derived from one of them:

1. **Proactive, but paced.** The companion speaks unprompted often enough to feel
   present (three unprompted turns per session) and rarely enough to never nag: at
   least two emitted turns must pass between proactive turns. A check-in run that
   would fire three times in a row collapses to its first utterance.
2. **Proposals need an ask; the ask is the proposal.** Anything that writes the cook's
   world — meal logs, notes, pantry corrections — must originate with the cook. The
   companion may *offer* a timer or a step advance proactively, because the proposal
   itself is the ask: nothing executes without the cook's explicit approval on the
   phone.
3. **Silence after repeated rejection.** If the cook turns down the same kind of
   suggestion twice, the companion stops making that kind of suggestion — but never
   goes silent entirely: check-ins are a different type and keep their own budget.
4. **Honesty over comfort on facts.** Warmth is in the framing ("that smell is
   sick-making — I'm sorry"), never in the facts: the camera look carries no verdict,
   and the rulebook's unknown is reported as an unknown. Cooks trust presence only
   when the presence does not lie.

Job focus: **coach** (presence during cooking) and **remember** (helping a solo cook
remember what worked). Planning openings are the planner design's turf; the companion
only touches plan-adjacent moments through `use-soon` reminders.

## 2. Knobs and rationale

| Knob | Value | Rationale (which commitment) |
|---|---|---|
| `turnBudget.maxUnpromptedTurns` | `3` | Presence with a ceiling (1). Three check-ins is the most attention a solo cook absorbs mid-cook; a fourth is the nagging threshold the `budget-exhaustion` and `mixed-focus-backoff` scripts pin. |
| `turnBudget.minGapTurns` | `2` | Anti-nag spacing (1): after a proactive turn, at least two emitted turns (user speech, or a prompted reply) must pass before the next one. `2` — not `1` — is what makes a run of back-to-back check-ins collapse to a single utterance, and it reads as natural pacing: speak, cook responds, companion acknowledges, *then* the companion may volunteer something again. |
| `suggestionType` | deterministic `[marker]` scan: `check-in`, `use-soon`, `step-offer` | Deterministic, offline, and per-source-turn (no counters), matching the shared contract. Types are few on purpose: the silence rule bites per type, so a small, well-chosen vocabulary makes the third-rejection rule legible. |
| `toolPolicy` rule 1 | deny `proposeMealLog`, `proposeSaveNote` proactively | The companion does not remember *for* you (2). Meal logs and notes are the cook's record of their world; the design denies these calls when unprompted with an explicit reason, and allows the identical calls when the cook's own words prompted them. |
| `toolPolicy` rule 2 | deny `proposeInventoryCorrection` proactively | Same principle, pantry surface (2): the companion does not write its inferences into your pantry unprompted. Corrections follow something the cook reports or scans (script: proactive guess denied, cook's report allowed). |
| `toolPolicy` — timer and step-advance **allowance** | not listed → allowed proactively | Justified against the same principle (2): `proposeTimerStart` and `proposeStepAdvance` always create a proposal with `requiredApproval: "explicit"`. The dispatch result at proposal time is `state: "proposed", requiredApproval: "explicit", userInitiated: false` — the phone asks, the cook approves, and only then does the timer start or the step advance. The proposal **is** the ask; denying it would remove the companion's most useful proactive help (hands-free timing) without adding any safety, because approval is already structural. |
| reads | not gated | Reads (`getPantrySnapshot`, `getRecipeCandidates`, `checkFoodSafety`, `requestCameraLook`) are allowed proactively and prompted: reading is how presence works, and the contract's deny-list applies to calls, so no read needs a proactive carve-out. |
| `isRejection` | shared `defaultRejectionMatcher` | Conservative shared matcher; the design adds no local vocabulary. Divergence here would make cross-design comparisons (the point of the three-way review) dishonest. |
| `systemPrompt` | documented-for-future-wiring | The offline replay does not consume it (shared contract); it is kept consistent with the knobs so a future live wiring can adopt it without a redesign. Its wording encodes commitment 4 verbatim ("never the verdict; report what you can and cannot assess"). |

### Proactive allowances, stated against the principle

The direction asked for explicit justification of any proactive timer/step allowance
against the "proposals need an ask" principle. The justification: the principle is
about **surprise in persisted state** — a log entry, a note, a pantry value that exists
after the session whether or not the cook noticed. A timer or step advance does not
exist until the cook approves it *on the phone screen*, which is exactly the "ask"
surface the principle wants. The scripts pin this: `timer-allowance` shows the offer
arriving as `state: "proposed"` with explicit approval required, and executing only
after the scripted approval; `proposal-gating` shows the denied memory writes never
reach proposal state at all.

## 3. What the replay shows

`bun run src/lechef/designs/companion/run.ts` replays 12 scripts through
`runDesignSession` with a per-script expectations table (exit nonzero on any mismatch).
Snapshot from the verified run on this branch:

- `control-prompted-only` — 6 turns kept, 0 suppressed; timer proposal executed; the
  equivalence baseline (nothing gated, nothing denied).
- `budget-exhaustion` — 3 spaced check-ins kept, the 4th suppressed (`budget-exhausted`).
- `checkin-run-collapse` — a run of 4 consecutive check-ins collapses to its first;
  3 suppressed (`min-gap`), the later plain reply survives.
- `use-soon-silence` — after two rejections the 3rd `use-soon` is suppressed
  (`suggestion-type-silenced`); the `check-in` two turns later still passes.
- `proposal-gating` — proactive `proposeMealLog`/`proposeSaveNote` denied with the
  design's reason; the same asks, prompted, pass and execute (`proposeMealLog` executed
  on approval, the second note left `proposed` — approval is per-proposal).
- `timer-allowance` — proactive timer offer allowed; dispatch result `state: "proposed"`,
  executed after approval.
- `inventory-correction-proactive` — proactive pantry correction denied with its own
  reason; the cook's report allowed.
- `burnt-smell-empathy` — reads pass, camera event recorded with `safetyVerdict: null`
  and explicit `cannotAssess`, food-safety answer with `sourcedCheck: null` (unknown,
  said as unknown).
- `use-soon-reminder` — accepted `use-soon` nudge flows into a read-only suggestion.
- `step-advance-allowance` — proactive step-offer allowed, executes on approval.
- `mixed-focus-backoff` — a terse cook gets `min-gap` on one early check-in and
  `budget-exhausted` on the fourth; exactly 3 unprompted turns survive.
- `remember-note-flow` — cook originates two notes and a meal log; all three executed.

Deterministic usage totals (turns/tokens/audio/frames/connected seconds) are printed
per script; the replay is fully offline (fake provider + fake phone).

## 4. Structure

- `design.ts` — the `LeChefDesign` config (only shared-layer import:
  `designs/contract.js`).
- `scripts/*.json` — 12 `SessionScript` fixtures, all `design: "companion"`, jobs
  `coach`/`remember`, `cameraMode: "push-to-look"`. Turn texts embed their suggestion
  marker (`[check-in]`, `[use-soon]`, `[step-offer]`) so the type scan stays
  deterministic.
- `run.ts` — the replay runner with the expectations table (per-script summary:
  suppressed turns with reasons, silenced suggestion types, policy denials, tool-call
  statuses, proposal states, usage; structural global checks: design stamp, no dropped
  actions, camera never a verdict).
- No `cores/` directory: the shared fake model + design runner express everything this
  design's offline behavior needs (studied `fakeModel.ts` and `run/harness.ts` first);
  a design-local core would have been an unused abstraction.

## 5. Limitations

- **The systemPrompt is not exercised.** The replay gates scripted turns; warmth and
  empathy live in script prose, not generated behavior. What is proven: the *gating
  skeleton* (pacing, silence, policy). What is not: that a live model behind this
  prompt produces the warmth.
- **Suggestion typing depends on markers.** In live wiring the model's raw text must
  be classified; the deterministic marker scan is a stand-in for that classifier.
- **`useSoon` pantry hints and recipe-fixture fields are script-local shapes**; the
  fake model stores fixtures opaquely, so they demonstrate the data path, not product
  semantics.
- **Time is frozen per session.** Real pacing depends on wall-clock gaps between
  turns, which the script model does not represent; `minGapTurns` is the
  counter-based proxy.
- **No audio/cost realism.** Usage totals count script-declared audio seconds and the
  fake model's token accounting; real cost measurement belongs to the harness's cost
  story, not this design.

## 6. Open questions

1. **Should a suppressed check-in ever leak a minimal "still here" utterance?** The
   current gate removes the turn entirely; a softer design might emit a single short
   acknowledgement on the first suppression. Needs product input (and probably a
   shared-layer concept — suppression-with-replacement — before it can be tested).
2. **Cross-session rejection memory.** Silence resets per session; a cook who rejects
   `use-soon` twice every session hears two nudges every session. Remembering
   rejections across sessions is a product decision with privacy implications.
3. **Is `step-offer` a suggestion type or a proposal?** It is both here (marker for
   pacing, `proposeStepAdvance` for execution). If the join wants suggestion-silence
   to also apply to the tool (reject the step-offer twice → the tool call is denied),
   that needs a shared-layer rule mapping suggestion types onto tool calls; reported
   as a wanted-but-not-made change below.
4. **Budget granularity.** One budget per session is blunt for long cooks; a
   per-N-minutes budget would need time semantics the script model lacks.

## 7. Wanted shared-layer changes (not made)

None blocking. Two observations for the join, both currently expressible without
changes: (a) the step-offer/tool silence linkage in open question 3 would want a
contract extension; (b) suppression-with-replacement (open question 1) would want a
`LeChefDesign` hook (e.g. `suppressedReplacement`) — both were left to the parent on
purpose.
