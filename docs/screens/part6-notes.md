# Part 6 notes — Shell S alternates and the quests/tour candidates

Continues `part5-notes.md`'s conventions. Part 6 covers two things: the
**Shell S alternate-shell screens** (Progress as a tab, Profile pushed
from it, Kitchen under the alternate chrome) and the two **CANDIDATE
screens** (weekly quests, the onboarding tour). The domain packages are
still not in this stack — every domain capability arrives through
protocol seams (host-injected services), the Parts 2–5 pattern.

**Status of this part:** FLDesignTokens 27/27 unchanged; FLScreens
345 distinct test cases passing on Linux (279 Part 1–5 baseline intact
+ 66 new Part 6 cases), 0 failures; FLDesignSystem builds on Linux. All
SwiftUI view bodies remain **UNVERIFIED-NATIVE** (see Native gaps).

## Module split (and why)

One new screen module and one shared helper, not five:

- **`FLProgress`** holds BOTH the Progress screen and the Profile
  screen. Progress and Profile share state vocabulary (household,
  evidence summaries, the provenance line), Profile is reached only
  from Progress, and splitting them would have created a target whose
  only contents were Profile's row routing. The Table precedent
  applies to identifiers too: Profile uses `fl.profile.` while living
  in the FLProgress target — ids name the screen, not the module.
- **`FLQuests`** and **`FLTour`** are separate targets **because they
  are candidates**: each can be dropped (delete target + tests) or
  promoted (flip the flag's default, remove the flag) with nothing
  else entangled. Entangling them in FLProgress would have made the
  candidate boundary a file boundary at best.
- **`FLScreenSupport`** gains `FLSavedFoodLine`: Progress's counter
  ("1.2 kg saved") and Quests' week caption ("620 g food saved") state
  the same number, so both derive their display from the one place and
  cannot drift. Same shape as `FLFitSummary`: numbers in, display
  strings out; negatives clamp to zero rather than rendering a debt.
- **Shell S's Kitchen composition lives INSIDE `FLKitchen`**
  (`ShellSKitchenViews.swift`) — see the next section.

Nothing in Part 6 forks or duplicates an existing screen.

## How Kitchen is reused under Shell S

Shell S is a **configuration of the Part 2 shell, not a second shell**:
`FLShellConfiguration.shellS` is two tabs (Kitchen, Progress) with Scan
in the native bottom-accessory slot and a badge display on tabs — the
same `FLShellViews` shell renders it; Part 6 added only the tab-badge
hook (`badgeDisplay`, default nil, iOS branch only; the macOS fallback
stays a plain tab list by design).

Under that configuration, Kitchen is the **same `KitchenView` with the
same state and the same intents** — `ShellSKitchenViews.swift` embeds
`KitchenView(state:)` and adds exactly two pieces of chrome around it:
the composition root (`fl.kitchen.shellSScreen`) and the "Explore
recipes" access row (`fl.kitchen.shellSExplore`), because Shell S has
no Explore tab and Explore must stay reachable. It declares no
`KitchenView` of its own, re-renders no Kitchen header, and builds no
tab bar — the composition cannot drift from Kitchen because there is
nothing to drift. `ShellSReuseTests` (in FLKitchenTests) pins the reuse
at the source level: embeds the real view, no `struct KitchenView`
re-declaration, no second `fl.kitchen.title`, no `TabView`/`tabItem`,
Apple-gated with the UNVERIFIED-NATIVE note.

## The candidate flags

Quests and the tour ship **OFF**. `QuestsViewState.enabled` and
`TourViewState.enabled` default to `false`; every action the state
layer could take (present, join, share, start, skip) is guarded on the
flag, so a flag-off candidate is unreachable even if the host wires it
by accident. The defaults are lint-pinned in
`Part6RawSourceLintTests` (the Part 3/4/5 raw-source lint convention
continues: 11 new pins covering Foundation-only state files,
Apple-gated views, candidate defaults, the quest-share field
allowlist, Profile's data boundaries, the tour's five-step cap,
Kitchen reuse, the shared saved-food grammar, shell-chrome exclusions,
and the `fl.` identifier prefixes).

Dropping a candidate = delete its target, its tests, and its lint
pins. Promoting = flip the default, remove the flag. Neither touches
FLProgress or anything else. Progress's "Weekly quests" entry row is
gated by the quests flag too, so Progress renders identically whether
or not the candidate exists — its absence is the off state.

## Quests: community-adjacent, privacy-safe by construction

SPEC §3.4: community cooks exclude pantry, health-profile, taste, and
exact-time data. The state layer enforces the line **structurally**:

1. `QuestSharePayload` is the only value a share ever builds — an
   explicit allowlist (quest id and name, servings, swaps, rating,
   optional one-line note). There is no field a pantry line, a health
   attribute, a taste embedding, or a timestamp could arrive in; the
   projection reads only the five fields of the host's cook record and
   drops everything else by construction. The lint bans the excluded
   vocabularies from the payload's declarations, the way Part 5 banned
   them from the Table's `LookResult`.
2. Aggregate counters ("14 cooking · 3 cooks made it") are
   host-supplied structured counts, never personal rows.
3. Rewards are display chips ("unlocks an explore filter") — the SPEC
   wins over any reading of the mock that smells of points, coins or a
   currency.

Offline joins queue with a **visible receipt** ("You're in — this
queued while offline."), applied on `.connectionRestored`; leaving is
quiet (no confirmation, no error). The share preview shows the exact
payload before anything sends; confirm and cancel are explicit.

## Tour: three promises, not a tutorial

The SPEC's binding shape: the tour is three promises — what the app
will do, what stays on the phone, what you can undo. One screen per
promise, **auto-returns home after each step** (the card comes down;
the host re-presents the next promise when it chooses — the state
machine's `returnedHome(nextIndex:)` stage is the contract), skip is
always available, back never goes before the first step, and a
dismissed or completed tour never re-arms for the session. Shortness
is enforced in the state layer: steps truncate to `maxSteps` (5) on
arrival, so the tour cannot quietly grow into an onboarding funnel.
Every word on the card is host-verbatim; the state layer owns the
machine, not the copy.

## Adopt-vs-adapt, per screen

- **Progress (H mock `shell-s-progress.html`)**: adopt the structure —
  counters row, week rows, quests/profile entries. Adapt: the mock's
  large mono counters have no matching type token (44-point and up);
  the views use existing screen-title/summary token roles rather than
  inventing a role or hard-coding a size. The counters row uses the
  shared `FLSavedFoodLine` for the saved-grams figure.
- **Profile (H mock `shell-s-profile.html`)**: adopt the sections
  (household, evidence, data controls). Adapt: the mock's Forget
  treatment as a destructive sheet became an inline confirmation +
  receipt + undo row, which is what the state machine models and what
  the SPEC's "you can undo" promise needs; the host-maintained clock
  (`now` on the state, refreshed by `.tick`) is the LeChef
  `lastKnownNow` pattern, not the mock's implied wall clock.
- **Kitchen under Shell S (H mock `shell-s-kitchen.html`)**: adopt the
  alternate arrangement (no Explore tab, Explore reachable from
  Kitchen, Scan in the accessory). Adapt: the mock's floating Scan orb
  is **not** rebuilt — the Part 2 shell's native bottom accessory is
  authoritative and already carries Scan in this configuration.
- **Quests (H mock `candidates-quests.html`)**: adopt the featured +
  "also this week" structure and the week counters. Adapt: reward as a
  chip (SPEC's no-currency line), share preview as an explicit
  container, join receipts for the offline queue. Where the mock and
  SPEC §3.4 disagreed on what sharing shows, the SPEC won.
- **Tour (H mock `candidates-tour.html`)**: adopt the three-promise
  card. Adapt: the mock's scrim became themed ink at reduced opacity
  (`fl(.fade)`) — the palette is a closed set with no scrim role;
  photos stay 3:2 through `PhotoLayoutRule`; the first step's fit
  meter is host-supplied (have/total/line) or absent.

## P-theme coverage through the mapping

No Part 6 screen or state touches a direction-specific type. Views
build against `Theme` / `FLRenderPaletteMapping` exactly like Parts
2–5: every colour, type, radius and spacing value comes from
FLDesignTokens through the theme, so swapping the H table for the P
table is a theme swap the views cannot observe. The raw-source lint
pins the no-hard-coded-values and no-direction-types conventions for
all five new view files. P's candidate references
(`docs/design-round/direction-p/`) were read as confirmation that the
shared-vocabulary approach holds (same structure, different palette);
they are presentation references, not a second source of truth.

## Native gaps

- All five new SwiftUI view files (`ProgressViews`, `ShellSKitchenViews`,
  `QuestsViews`, `TourViews`, plus the shell badge hook) are
  Apple-gated `#if canImport(UIKit) || canImport(AppKit)` and marked
  UNVERIFIED-NATIVE: **no native toolchain ran in this part**, so
  visual behaviour, keyboard access, accessibility traits, Dynamic
  Type and reduced-motion behaviour are unverified. The identifiers
  the views set are inventoried in `a11y-identifiers.md`; the state
  machines, derivations, gating and privacy exclusions behind them are
  Linux-tested.
- The iOS 26 bottom-accessory Scan placement compiles against the
  Part 2 API but has only been exercised in code review, not on a
  device.
- Host-routed rows (taste profile, cookbook records, export, sign out)
  record nothing in the state layer — their destinations are the
  host's, and their verification is the host's.

## Verification measured

- `packages/FLDesignTokens`: `swift test` → **27 passed, 0 failed** (unchanged).
- `packages/FLScreens`: `swift test` → **345 distinct test cases
  passed, 0 failed** = the 279-case Part 1–5 baseline intact (per
  class: Explore 21, FLFitSummary 12, Kitchen 15, LeChef 70, LintTests
  3, Part3 6, Part4 8, Part5 10, Recipe 18, Scan 44, Support 12, Table
  16, Taste 27, Tonight 17) **plus 66 new Part 6 cases** (Part6 lint
  11, Profile 12, Progress 10, Quests 17, Shell S reuse 3, Tour 13).
- `packages/FLDesignSystem`: `swift build` → complete on Linux.
