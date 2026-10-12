# FLScreens — the Tonight and Kitchen screen families

Part 2 of the FridgeLuck screen overhaul (PLAN suite F). This package
carries the Tonight and Kitchen screens as three targets:

- **FLScreenSupport** — the two round decisions as shared, Linux-tested
  code: `PhotoLayoutRule` (photo areas are 3:2, capped at 40% of available
  height, so Tonight's primary action stays above the tab bar on first
  paint) and `FLShellConfiguration`/`FLShellTab` (the shell's tab list is
  configuration: `standard` = four tabs with Scan as the trailing
  search-role tab; `shellS` = Kitchen + Progress with Scan as the native
  bottom accessory). Also `FLRenderPaletteMapping`, the variant → palette
  table mapping the render matrix uses, with an explicit
  `isProvisional` tripwire (see "H/P palette tables" below). The
  Apple-gated `FLShellView` lives here too.
- **FLTonight** — the Tonight screen: `TonightViewState`, `TonightFit`
  (the honest fit-line grammar), `TonightIntent`, the reducer, and the
  Apple-gated `TonightView`.
- **FLKitchen** — the Kitchen screen: `KitchenViewState` (scans observe /
  purchases add; nothing auto-expires; search ends in manual entry),
  `KitchenIntent`, the reducer, and the Apple-gated `KitchenView`. The
  reconciliation pill pair rides the `pillIdle` / `pillGone` warm surface
  fills from FLDesignTokens.

## What is verified

`swift build && swift test` is green on Linux for this package:

- 17 Tonight state tests, 15 Kitchen state tests, 12 support tests
  (photo rule, shell configurations, palette-mapping totality), and
  3 lint tests — all passing on `x86_64-unknown-linux-gnu`, Swift 6.4.
- **The lint test** scans every source file in this package (including the
  gated SwiftUI sections, which Linux never type-checks) and fails the
  suite if any screen source contains a hex colour literal, a font name,
  or a direct font construction. This is the enforcement behind Sam's
  round decision that the morning pick replaces Direction H BY SWAPPING
  THEME TOKENS: no colour, type, radius or spacing value is hard-coded in
  a screen.
- FLDesignTokens (with the additive pill fills) and FLDesignSystem build
  on Linux; the token test suite passes 20/20 after the additive change
  documented below.

## UNVERIFIED-NATIVE — read before trusting any visual claim

The following parts of this package have **never been compiled or run by a
SwiftUI-capable toolchain**. They are gated behind
`#if canImport(UIKit) || canImport(AppKit)` and compile to an empty module
on Linux. Nothing in this package, its tests, or this README should be
read as claiming they compile, render, or behave:

- `Sources/FLScreenSupport/FLShellViews.swift` — `FLShellView` on native
  `TabView`/`Tab`/`TabRole`/`tabViewBottomAccessory` (iOS 18+ APIs).
- `Sources/FLTonight/TonightViews.swift` — `TonightView` (hero card,
  photo area, fit line, constraint offer, taste question).
- `Sources/FLKitchen/KitchenViews.swift` — `KitchenView` (search field,
  reconciliation pills, dense rows, edit states).

Real SwiftUI compilation and rendering need **a Mac or approved CI**. The
staged proposal `ci/pending-workflows/screens-renders.yml` (HELD — never
installed) would render Tonight and Kitchen in both the H and P palettes
and both shell configurations on a macOS runner and upload PNG artifacts.
Until that runs on Apple hardware, the visual layer is UNVERIFIED-NATIVE
by construction, and no screenshot, render, or layout measurement of these
views exists. In particular:

- The search-role Scan tab's PRESENTATION is the system's (iOS may restyle
  it or open it into a search presentation). The custom label and icon on
  `Tab(_:systemImage:role:.search)` are supported per the round decision;
  how the search presentation actually looks for a scanner flow is not
  verified. Fallback if the presentation is wrong: Scan as a prominent
  action on Tonight and Kitchen — both screens already ship those actions.
- `PhotoLayoutRule` arithmetic is Linux-tested; its application inside
  `GeometryReader` in `TonightView` is not.

## Additive API this package added to FLDesignTokens

The base branch (`overhaul/design-system`) had not landed the Kitchen
pill fills by delivery, so this branch adds them additively (per the task
brief's fallback):

- `ColorRole.pillIdle` and `ColorRole.pillGone` (two new cases, documented
  in `Palette.swift`).
- `Palette` gains `pillIdle`/`pillGone` stored properties; the `init`
  parameters are defaulted so pre-existing call sites compile unchanged;
  `token(_:)` resolves the new roles; all three `Theme.palette` tables
  (paper, hob, dark) pass explicit values with contrast rationale
  (paper: ink on pillIdle ≈ 13:1, ink2 on pillGone ≈ 5.3:1; hob: ink on
  pillIdle ≈ 11:1, ink2 on pillGone ≈ 5.2:1).
- `CompletenessTests.testColourRolesComplete`'s expected list was extended
  by the two names (its own failure message instructs exactly this for
  additive roles). Contrast tests pass unchanged.

If the base lands its own pill tokens, drop this additive block in favour
of the upstream one and re-point the Kitchen pills.

## H/P palette tables (and the deliberate tripwire)

The render matrix must render both variants, but the H and P palette
tables had not landed in the base at delivery. `FLRenderPaletteMapping`
therefore resolves BOTH variants to the carried table and exposes
`isProvisional == true`. The tripwire test
(`SupportTests.testProvisionalMappingTripwire`) FAILS ON PURPOSE once the
base lands real per-variant tables, so the mapping cannot silently keep
rendering one palette twice and call it a comparison.

## Accessibility identifiers are PROPOSED, not agreed

`docs/screens/a11y-identifiers.md` (in the repository root of this clone)
proposes the `fl.`-prefixed identifiers used by the views. The evaluation
`CONTRACTS.md` is absent on alpha, so these are a **request for
confirmation** — they are not an agreed contract, and nothing should key
on them until the evaluation side confirms.

## Boundaries

This package does not touch `.github/workflows/`, `project.yml`, any
workflow-producing operation, or any branch. The render workflow is a
staged proposal. Git operations on this clone belong to the parent thread.
