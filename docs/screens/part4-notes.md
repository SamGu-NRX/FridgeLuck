# Part 4 delivery: Scan capture-and-review, Taste profile

Continuation of `part3-notes.md` (Part 3, branch
`overhaul/screens-explore-table` at `cf792e9`). Same ground rules, still
enforced by the lint suite for the two new view files: every colour
through `Theme.swiftColor`, every type through `.flType`, every radius
through `Radius`, every spacing through `Theme.layout` (`LayoutTokens`),
photo geometry only through `PhotoLayoutRule`. Nothing hard-coded; both
screens build against `FLRenderPaletteMapping` / `Theme`, never a
direction-specific type, so Direction P is a theme swap, not a variant.
The Scan destination wires into the Part 2 shell's existing search-role
tab slot; Tonight's and Kitchen's prominent-Scan fallback actions remain
the other entrances — no custom dock, no hand-rolled centre orb.

## Module split

- **`Sources/FLScan`** — the grocery capture-and-review flow: landing,
  capture, analysing, review, commit dock, problem paths (state,
  intent, reducer, views).
- **`Sources/FLTasteProfile`** — the on-device taste editor: learning
  ledger, restrictions, remembered notes, setup summary, export,
  forget-all (state, intent, reducer, views).

Two targets rather than one, and the split is not "one screen, one
target" bookkeeping: Scan and Taste share no state, no intents and no
vocabulary — Scan's data is the pantry read and the capture session,
Taste's is host-verbatim evidence and on-device memory. What they share
(launch posture, commit-dock pattern, evidence lines) already lives in
`FLDesignSystem` / `FLScreenSupport`, so a combined module would couple
two unrelated reducers for no shared code. The name is
`FLTasteProfile`, not `FLTaste`: the repo already ships an `FLTaste`
domain package, and a same-named screen module invites an import
collision in every file that touches both. `FLTasteProfile` also reads
as the screen it is. Both targets split the Part 2/3 way —
Foundation-only view state + typed intents + reducers (Linux-tested),
SwiftUI views Apple-gated per `#if canImport` — and consume services
through the same host seams as every earlier screen. Test targets are
`FLScanTests` and `FLTasteProfileTests`, keeping the taste screen's
tests distinct from the domain package's own suite.

## Scan — adopted vs. adapted

**Adopted from `direction-h/scan-review.html`:** the staged spine
(land → capture → analysing → review → committed) with the mock's
review screen as the centrepiece; the header tally ("9 seen · 7 sure")
in mono as the only number besides quantities; the "Looks right" /
"Needs you" section split, with uncertain rows presenting what the scan
saw and name options instead of a verdict; the commit dock captioned
"Tonight's pick updates when you do."; the quality gate as a notice
over the photo ("Too dark to read" / "Too blurry") rather than a modal;
recognition failure keeping the photo and offering "Try again" /
"Missed something? Add by name" — an escape, never a dead end; the
plate run's offer ("This looks like a meal. Log it instead?") answered
before the review proceeds.

**Adapted — three decisions worth writing down:**

- **No confidence number.** The mock's recognition rows show percentages.
  A model's certainty is not a quantity the user can check against a
  shelf, and a wrong number read as a promise is worse than a question.
  Items are *sure* or *needs you*; the lint suite bans the vocabulary
  in Scan sources.
- **Duplicates reconcile, they don't guess.** The mock folds existing
  pantry items into the tally. The scan observes — "In your kitchen
  already — a scan never adds", with "Still N" / "Bought more" chips —
  and unanswered duplicate rows never become a write; they ride the
  commit as observations, and unanswered *needs-you* rows continue to
  Kitchen's needs-a-look queue instead of blocking the commit.
- **Quantities arrive verbatim.** Recognised or receipt-line quantities
  render as read; an unknown amount stays "?" — the scan never invents
  grams from the look of a bag.

The capture stage itself is native iOS 26: the shutter is a plain
button with the capture stages behind `#if canImport(UIKit)` (and the
AVFoundation capture path compile-gated the same way — see gaps).
The review photo draws 3:2 through `PhotoLayoutRule`, capped at 40% of
screen height, placeholder until the host supplies a real capture
pipeline.

## Taste profile — adopted vs. adapted

**Adopted from `direction-h/taste-profile.html`:** the learning ledger
as sentences with host-verbatim evidence tags ("18 of 23" — the
denominator grammar is the host's, never derived in the view); the
Right / Wrong judgements with one- judgement undo; the offer row
("Suggest some" host-routed to Explore's filter, "Not interested" this
once, "Never suggest" per-sentence-kind suppression — suppression is
separate from rejection by design); restrictions as a list where setup
items are locked ("Set in setup. Edited there, never here."); "LeChef
remembers" notes with per-note "Forget this note" and an undoable
receipt ("Forgotten."); "Forget everything" behind a confirmation whose
cancel is "Keep everything", and which preserves restrictions — safety
settings are not taste data; the on-device footer line and "Export
everything I know about you" as the only data out.

**Adapted:** the mock's dashboard-style two-column arrangement becomes
a single scrolling section list (the Part 2/3 adaptation for pod
layouts and dynamic type); the mock's inline editor toggles become a
native sheet for the restrictions editor with `presentationDetents`;
`FLTasteSentence` from the design system is *not* reused — it renders
the domain package's sentence type, and this screen's state is a
separate, smaller value with its own judgement semantics; the screens
own their own row rendering rather than bridging two type systems.

## Direction P coverage

Both variants resolve through `FLRenderPaletteMapping`: `.h` and `.p`
each map to their real FLDesignTokens table (`DirectionH.swift` /
`DirectionP.swift`, `isProvisional` false since Part 2). No screen type
mentions a direction; the same `ScanViews` / `TasteViews` render either
theme from `Theme.swiftColor(_, in: scheme)` + `.flType` + `Radius` +
`Theme.layout` alone, and the Part 4 lint suite asserts the view files
name neither direction and consume the mapping's scheme environment.
The Part 2 mapping tests (`SupportTests`, 12) keep both tables
resolving; the Part 4 state tests are palette-agnostic by
construction. What the P mocks show for these screens (pill chrome,
mono-only voice) stays a token-table difference — no screen branches
on it, per the round constraints.

## Native gaps

- **Camera on Linux:** the capture stage compiles Apple-gated
  (`#if canImport(UIKit)`), with the AVFoundation capture path behind
  the same guard pattern; there is no camera and no AVFoundation on
  Linux, so the shutter-to-image pipeline is compile-verified only.
  All capture-adjacent *state* (quality gate, camera-refused escape,
  retake) is Foundation-tested without hardware.
- **Apple-toolchain render verification:** the two new view files are
  Apple-gated and compile only on an Apple toolchain; this delivery
  proves the Foundation state, reducers, lint contracts and Linux
  package graph. First-paint on device (Liquid Glass behaviour,
  dynamic-type reflow, the review photo's `PhotoLayoutRule` framing
  with real captures) is unverified until the host builds the app
  target.
- **Live capture preview:** the mocks show a live camera feed with a
  focus reticle; the native capture stage frames the preview space and
  hands off to AVFoundation behind the host seam — the reticle and
  session polish belong to the host capture integration, not this
  layer.
- **Recognition itself is a host service:** the analysing stage's
  streamed arrivals are state-driven (the reducer coalesces rows as
  they land); the actual shelf-reading model is outside the screens,
  consumed through the same service seams as Parts 2–3.

## Verification (measured this delivery)

- `packages/FLDesignTokens`: `swift test` → **27 tests, 0 failures**
  (unchanged).
- `packages/FLScreens`: `swift test` → **199 tests, 0 failures** —
  the 120-test Part 3 baseline intact exactly (Tonight 17, Kitchen 15,
  Explore 21, Recipe 18, Table 16, FLFitSummary 12, Support/mapping 12,
  lint 3+6) plus **79 new**: ScanStateTests 44, TasteStateTests 27,
  Part 4 raw-source lint 8.
- `packages/FLDesignSystem`: `swift build` → complete on Linux.
- `docs/screens/a11y-identifiers.md`: extended with `fl.scan.*` and
  `fl.taste.*` tables drawn from the identifiers the views actually
  set (label copy checked verbatim against the view sources).
