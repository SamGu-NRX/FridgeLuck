# Part 5 delivery: the LeChef cook mode

Continuation of `part4-notes.md` (Scan capture-and-review, Taste profile,
landed at `b3db8b5` on `overhaul/screens-scan-taste`). Same ground rules,
still enforced by the lint suite for the new files: every colour through
`Theme.swiftColor`, every type through `.flType`, every radius through
`Radius`, every spacing through `Theme.layout` (`Density.deciding`).
Nothing hard-coded; everything builds against `FLRenderPaletteMapping` /
`Theme`, never a direction-specific type, so Direction P is a theme swap,
not a variant. One difference from Parts 2–4: LeChef is NOT a tab and
never touches the Part 2 shell — it is a presentation/destination seam
the host drives, entered from a recipe or from Tonight's pick.

## Module decision: one target, `FLLeChef`

The cook flow ships as a single target with four source files
(`LeChefViewState`, `LeChefPersistedState`, `LeChefIntent`, `LeChefViews`)
and one test target (`FLLeChefTests`), inside `packages/FLScreens`.

- One state machine, not five screens. Plan, substitute, coach, adapt and
  remember are five JOBS over one live session: the same clock, the same
  step index, the same timer list, the same proposal queue. Parts 2–4
  split targets when two screens share no vocabulary (the Part 4 rule).
  Here the opposite holds — split the session and the pieces start
  passing each other's state through the host. The five jobs get separate
  sections in the state file and separate test suites, which preserves
  the readability a split would have bought.
- The name is `FLLeChef` (not `FLCook`, not `FLCookMode`): the product
  voice calls the cook "LeChef", the SPEC's section is LeChef, and the
  accessibility identifiers follow (`fl.lechef.*`).
- Domain capabilities (feasibility, substitutions, food safety, assistant
  routing) live in separate, unmerged packages. Everything flows through
  host-injected service seams, exactly like Parts 2–4: the host feeds
  host-verbatim strings and typed values; the state layer never imports
  a domain package. The Linux tests prove the seam by construction —
  there is nothing else on the classpath to import.

## Contracts, and where they got enforced

- **Five jobs, local core, offline to completion.** Every job declares a
  local core ("Steps and timers run on this phone", "Rescaling runs on
  this phone", …) surfaced in the job strip. `LeChefOfflineTests`
  completes a whole cook — enter, four steps, a timer firing, a voice
  command, a substitution read, the explicit save — with the link pinned
  offline and zero assistant output. The check lines re-earn themselves
  on the next tick after a reopen rather than being restated from the
  snapshot.
- **Reads vs mutations.** `Proposal.isApplied` distinguishes the two.
  Reads (information, look results, adapt announcements) apply on
  delivery with no action chrome. Mutations (substitution, adapt change)
  wait for `approveProposal(id:)` — and `VoiceCommand` has no case that
  can reach the approval path; the reducer ignores voice for a pending
  mutation (tested). Timer chips are the third thing: phone-controlled,
  local — `applyTimerSuggestion` routes to the timer path, not the
  approval path (SPEC §4; the H mock's "Show it" beside a timer
  suggestion would have blurred exactly this line — see divergences).
- **Timers are the state machine's.** Set, pause (tap), remove
  (long-press) and the host's `tick` all live in the reducer; a fired
  timer is information — it adds a check line and never advances a step.
  Deadlines are epoch-fixed from the session's last known clock reading;
  any intent that carries a timestamp (`enter`, `nextStep`, `tick`)
  updates that clock. Park/resume never rewrites a deadline — resume
  recomputes the epoch so the remaining seconds are continuous.
- **Camera: push-to-look is the built candidate.** The viewfinder is an
  overlay; capture is explicit (`Send one frame` / `3-second clip`),
  send is explicit, problems are escape lines ("Couldn't send that look.
  Try again or keep cooking."), never dead ends. The lifecycle is
  `requestLook → captureLook → lookCaptured → sendLook → uploading →
  result/failed → retry/cancel`, reducer-owned; the capture and upload
  pipelines are the host's. Continuous camera + voice exists only as an
  explicitly flagged, unbuilt candidate: `LookCandidate.continuous`
  renders a "not built in this release" row (lint-tested: the built
  candidate must be push-to-look).
- **A look never yields a verdict.** `LookResult` carries
  `observedLines` (host-verbatim observations) and nothing else. The
  struct has no field a doneness, safety, temperature or confidence claim
  could arrive in — the raw-source lint slices the declaration range and
  fails if one grows. Every result the display grammar renders is paired
  with "A look can't check doneness or safety — the thermometer decides."
- **Voice is opt-in per cook; chat is the fallback.** `isTranscriptOn`
  defaults false; the row reads "Voice off — Just the steps" with a
  quiet "Turn on". The five-word vocabulary (next, back, repeat, show,
  timer N minutes) is on-device and ignored while the toggle is off;
  chat exists only behind it. The transcript lives in the session, not
  the snapshot.
- **Nothing transient persists.** `LeChefPersistedState` is an explicit
  allowlist (stage, revision id, dish, servings, step index, startedAt,
  timers, applied substitution ids, rating, saved note) — by construction
  there is no field a frame, a clip, a transcript turn or a look result
  could occupy. Two tests hold the line: the raw-source lint bans the
  tokens from declarations, and the persistence tests walk the mirror and
  record a session full of transient data, then assert the recording is
  clean. A draft note never rides the snapshot; only the explicit save
  does.

## Adopt vs adapt (the Direction H mock)

Adopted as-is: the cook palette pinned across the whole surface (it does
not recolour per ambient scheme, like the timer tile); the step card with
its progress segments; timer tiles as the one card type via the shared
`FLTimerTile`; the offline line under the header; the check line's
wording ("Rice done — stir the sauce in"); the "Kill the app at step 4"
resume contract; "Voice off — Just the steps" as the entrance; the
push-to-look viewfinder row; the complete surface's rating, note,
privacy line and Done.

Adapted, and why:

- **Serif completion title.** The mock sets the complete surface's title
  in a serif display face. There is no serif role in `TypeTokens`, and
  inventing one would leak a one-screen font decision into the shared
  type system without a design round. The surface uses `.screenTitle`.
  If a serif display role is ever added, this is a one-line swap.
- **Inline mono quantity runs inside step text.** The mock highlights
  quantities mid-sentence in mono. SwiftUI has no token-backed way to do
  inline styled runs over host text without hand-parsing the step string
  in the view layer — and the step text is host-verbatim, so the screen
  layer refuses to parse it (the same rule that keeps recipes unparsed
  in Parts 3–4). The step renders in `.body`; quantities stay in-line,
  unstyled.
- **Timer suggestion chip.** The H mock asks "Want a 2 min timer to
  check again?" with an action labelled "Show it" — which reads as a
  look/camera verb sitting on a timer proposal, and tells the cook
  nothing about what will happen. The P mock's chip, "Set 2 min timer",
  names the action. Adopted P's wording via `timerSuggestionTitle`
  (whole minutes, seconds under a minute).
- **Amplitude-driven voice indicator.** The mock's mic indicator is
  driven by real input amplitude. There is no host service for amplitude
  in this layer's seams, and faking a pulse with static data would
  violate the honesty rules. The indicator is a static shape while
  listening, exactly as the mock specifies for muted/offline.
- **Timers from the step.** The mock shows timers suggested by the step's
  content. Steps are host-verbatim strings; deriving timers from prose is
  host work. The surface exposes the add-timer tile and the state machine
  honours whatever the host dispatches (`setTimer`, or a step-suggested
  chip).

## SPEC vs mock copy divergences

- The SPEC's line-156 correction (cook-mode doneness and swap copy)
  targets the Direction F mocks. The H and P cook-lechef mocks already
  carry the corrected contract: doneness is "the checkable thermometer
  test (74 °C, USDA FSIS), never colour or time alone", and a camera look
  "describes browning and says what it cannot assess". No conflict found
  in this mock pair; the state layer implements the SPEC wording
  regardless.
- The H mock's "Show it" timer-suggestion action is the one real
  divergence: it conflicts with the SPEC's distinction between
  phone-controlled timers and assistant proposals by dressing the chip
  as something to "show". Resolved in favour of the SPEC + P wording
  (above).
- No substitution copy appears in either cook-lechef mock, so the
  substitution proposal renders from the SPEC contract: it describes the
  difference, names what changes in the step, and never promises "no
  change" or "same taste". The proposal's read/mutation split and
  allergen re-check note come from the SPEC, not the mock.

## P-theme coverage through the mapping

Nothing in `Sources/FLLeChef` names a direction (lint-tested). The
surface resolves every colour through `Theme.swiftColor(_, in: .hob)` —
the cook palette — and every type/radius/spacing through the shared
tokens, so both direction themes are covered by `FLRenderPaletteMapping`'s
tables: whichever theme the host configures, the cook palette resolves
from that direction's H/P table pair. The P mock was checked as a
presentation reference (its "Set 2 min timer" wording adopted; its
warm-charcoal timer tile confirmed against `FLTimerTile`). What is NOT
verified natively: rendered pixels for either theme — see native gaps.

## Native gaps (unverified or host-owned)

- **UNVERIFIED-NATIVE, all of `LeChefViews.swift`.** The view file is
  Apple-gated (`#if canImport(UIKit) || canImport(AppKit)`) and has
  never been compiled by a SwiftUI-capable toolchain — this stack builds
  on Linux only. View names, layout calls and modifier chains are
  written to compile but are unproven until an Apple build runs. Same
  caveat as Parts 2–4, now covering one more file.
- **Camera and microphone.** The capture, upload, transcription and
  voice-note flows are host seams by design (the state layer dispatches
  intents and renders what the host reports). The Apple-side work this
  implies — `AVCaptureSession` wiring, permissions strings, the
  transcription pipeline, clip encoding capped at 3 s — is unauthored
  here and is the host task that consumes `LeChefIntent.captureLook` /
  `.lookCaptured` / `.draftVoiceNote`.
- **Dynamic type and reduced motion.** The surfaces use token-backed
  type so they scale, and the check-line/tick animations inherit the
  shared design system's motion rules, but neither has been exercised in
  a real Apple render. The mock's crossfade-under-stable-frame step
  change (220 ms) is unimplemented — it needs a matched-geometry
  transition the view layer can only verify visually.
- **Presentation mechanics.** Whether the host presents LeChef full
  screen, as a sheet, or as a navigation destination is the host's call
  (the SPEC allows all three; the views are agnostic behind
  `fl.lechef.screen`). Keyboard avoidance inside the chat field, and
  VoiceOver roasting order on the combined step card, are native-render
  verification items.
- **The `fl.lechef.*` identifier table** in `a11y-identifiers.md` remains
  a PROPOSAL like the rest of that file — nothing external should key on
  it until evaluation confirms.

## Tests

`cd packages/FLScreens && swift test`: 279 test cases, 0 failures
(199 baseline + 80 new: stage 10, steps 7, timers 8, proposals 10, look
8, voice 6, remember 8, offline 1, persistence 6, display 6, Part 5 lint
10). `packages/FLDesignTokens`: 27 tests, 0 failures (unchanged).
`packages/FLDesignSystem`: builds on Linux. The three failures the first
run exposed are recorded above (the clock rule, the
restore-without-duration decision, and the look-pairing lint binding to
the actual rendering path) — all three are model-first fixes, not
test-first ones.

## Review fix (PR #121, BLOCK item 4)

The reviewer was right that the timer clock could start at zero: the
sentence above ("any intent that carries a timestamp (`enter`, …)
updates that clock") described the intent contract, but the code did not
honour it — `.enter` built its fresh state with `lastKnownNow` at the
default zero, so a timer set before the next timestamped intent got an
epoch-zero deadline and the on-screen tile rendered expired (0:00)
immediately. Fixed at the source: `.enter` now seeds `lastKnownNow` from
the host's clock reading, and the persisted-restore hydration runs the
timer machine's one firing rule (`resolvingExpiredTimers`, shared with
the reducer's `tick`) so an already-passed deadline resolves to the
expired/ringing state — check line earned once — instead of a silent
zero, while a still-counting deadline shows deadline − now and a timer
with no persisted deadline is left untouched. Seeding is initialization,
not an intent: the reducer stays the timers' only authority, and no
state-layer path reads a wall clock — every `now` is host-supplied (the
Part 6 host-clock convention). Five seeding tests added
(`LeChefTimerSeedingTests`); the suite is 284 test cases, 0 failures.
