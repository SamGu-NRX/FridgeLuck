# Progress flow — evidence ledger

Host: Debian 13 Linux, Swift 6.4 (x86_64-unknown-linux-gnu). No Xcode, no macOS, no
simulator. Every row below states its verification status honestly. Nothing here is
webmocked; Playwright/axe were not used (web-only tools — this is a native surface).

Suite: `swift test --package-path apps/ios/Tools/progress-flow-check` — 39 tests, all
passing (M4 log: `progress-flow-check-m4.log`).

## Required checks

| Check | Status | Evidence | How to run / complete |
|---|---|---|---|
| Contrast | **verified-on-host** (math) | `ProgressContrastTests` computes WCAG 2.x ratios from the actual `AppTheme.swift` token values — printed values from the committed M4 log: textPrimary/bg = 13.94:1 light, 16.05:1 dark; textPrimary/surface = 15.46:1 light, 13.76:1 dark; accent/bg = 3.65:1 light, 6.37:1 dark; sage/bg = 3.10:1 light, 7.83:1 dark; textSecondary/bg = 3.66:1 light, 8.78:1 dark. | Rerun `swift test` in the package; every ratio prints in the log. |
| Contrast — sage tint finding | **found by the test, fixed in UI** | The insight row originally sat on an 8% sage tint; sage on that tint computes 2.87:1 — below the 3:1 graphics threshold. The tint was removed (plain page background: sage 3.10:1 light, 7.83:1 dark — both pass). | Regression-protected by `testRowIconsMeetGraphicsThreshold`. |
| Contrast — flagged gap | **finding, not fixed** | Light-mode `textSecondary` on `bg` computes 3.66:1 — below AA for small text. This is the app-wide subtitle convention (every FLSectionHeader), not a Progress-specific regression. Provenance-note body text was therefore rendered in `textPrimary` (13.94:1); the disclosure toggle keeps `textSecondary` as an interactive label at large-text threshold. | A design-system decision (darken `textSecondary` or restrict it to large text) is out of this task's file scope; track it as a design-system issue. |
| Labels / traits | **verified-on-host** (logic) | `ProgressSourceNotesTests` asserts the on-demand wording; meal-card tap targets expose `.isButton` traits + hint in source (`ProgressRecentMealsSection`); "Log a Meal" entry carries `fork.knife` + explicit `accessibilityLabel`. Trait/label assertions for view bodies cannot run off-host — those specific lines are **source-asserted**, listed under the Xcode row. | On macOS: run the app and inspect with Accessibility Inspector; or add the `FridgeLuckUITests` audit below. |
| Keyboard / VoiceOver traversal | **unexecuted-on-host** | No simulator; SwiftUI keyboard ordering cannot be exercised on Linux. Source uses standard Button/Picker controls (system focus order). | On macOS: run `Scripts/capture-fixtures.sh`, which drives the XCUITest accessibility audit (`performAccessibilityAudit()`) if the UI-test target exists. |
| Large type (Dynamic Type) | **unexecuted-on-host** | Requires a simulator. Source uses AppTheme.Typography semantic fonts throughout (system text styles scale). | On macOS: launch with Dynamic Type XXL and capture — extend `capture-fixtures.sh` with a `-FL_DYN_TYPE_XXL` leg. |
| Reduced motion | **source-asserted** | Convention followed per existing codebase practice: every entrance/animation in the touched views gates on `@Environment(\.accessibilityReduceMotion)` and passes `nil` animations (header, sections, disclosure, hero ring). No central helper exists in the repo, so no unit test is possible. | On macOS: enable Reduce Motion in the simulator, exercise the tab, record a screen recording. |
| Screenshots at 390x844 / 1440x900 | **unexecuted-on-host** | `Scripts/capture-fixtures.sh` is committed and refuses to run off-macOS (exit 1 with reason). No PNGs exist; none were fabricated. | On macOS: run `Scripts/capture-fixtures.sh /path/to/FridgeLuck.xcodeproj`. Prerequisite: the `FL_SEED_PROGRESS_FIXTURES=1` DEBUG seeding hook (documented in the script header). |
| Native a11y audit (XCUITest) | **unexecuted-on-host** | Same script; records SKIP with reason if no UI-test target exists in the generated project. | Same as above. |
| Full iOS app compilation | **unexecuted-on-host / PR CI** | Linux cannot build the app target. The draft PR's GitHub CI run (macos-26, `ios-ci.yml`, triggers on pull_request) is the hosted compilation evidence. | Check the PR's checks list on GitHub. |

## Behavior checks covered by the on-host suite (39 tests)

- Portion edit changes aggregates; date shift moves a day across buckets; profile/goal
  change invalidates goal-dependent outputs (seeded synthetic DB through the real
  migrations and `PersonalizationService.recordCooking`).
- Unknown days render as "no data" (never 0); averages exclude unknown days; coverage
  summary states "N of M days with data".
- Source selection is explicit (`localJournal` vs `appleHealth`), fallback reasons are
  surfaced, sources are never blended.
- Suggested vs confirmed target provenance drives the "Suggested target" pill and note.
- Range-state ownership: cancellation of superseded loads, stop() on view close,
  last-good reading retained on failure, revision-triggered refresh.
- First-log/empty scenario, deletion, and return navigation through existing seams.
- Revision-token observation fires on portion/date/profile changes (the dimensions the
  shared dashboard observer omits).
