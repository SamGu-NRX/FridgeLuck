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
