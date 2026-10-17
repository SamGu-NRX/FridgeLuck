# FridgeLuck Design System — Part 1 delivery

The two design-system packages, authored out-of-repo per the task boundary.
Everything here is drop-in: `packages/` moves into the repo verbatim; the two
integration proposals (`ci/pending-workflows/…`, `project.yml.hook.md`) are
staged for approval and never install themselves.

## Layout

```
design-system/
├── packages/
│   ├── FLDesignTokens/          Foundation-only token package (Linux-verified)
│   │   ├── Package.swift        tools 6.2; platforms iOS 26 / macOS 15; no deps
│   │   ├── Sources/FLDesignTokens/
│   │   │   ├── ColorToken.swift        raw hex colours + semantic roles (ink/ink2/ink3, yolk, rule/rule2, bg…)
│   │   │   ├── Palette.swift           paper / hob / dark palettes, FLScheme, WCAG ratio math
│   │   │   ├── DirectionH.swift       Direction H palettes (linen/walnut/terracotta; dark = Twilight Warmth; cook) + kitchen pills
│   │   │   ├── DirectionP.swift       Direction P palettes (Sam's adjusted hexes incl. the four derived text inks) + chip/plate roles
│   │   │   ├── LayoutTokens.swift     theme-swappable shell/photo rules (3:2 frames, 40% height cap) per Theme/DirectionH/DirectionP
│   │   │   ├── TypeRole.swift          type roles, dynamic-type anchors, mono numerals
│   │   │   ├── Density.swift           spacing grid + dense row metrics
│   │   │   ├── Radius.swift            closed radius set (hairline..card)
│   │   │   ├── Motion.swift            five named motions + press tokens (0.97 / 120 ms)
│   │   │   └── Haptics.swift           haptic roles
│   │   └── Tests/FLDesignTokensTests/  27 tests across ContrastTests / CompletenessTests /
│   │                               InvariantTests / DirectionContrastTests / DirectionTokensTests
│   └── FLDesignSystem/          SwiftUI component package (macOS/iOS-compiled)
│       ├── Package.swift        depends on FLDesignTokens by path
│       ├── Sources/FLDesignSystem/
│       │   ├── ThemeBridge.swift       scheme env, flType/flTracking, FLHaptics, FLButtonStyle
│       │   ├── FLButton.swift          the only button (primary/secondary/text)
│       │   ├── FLChip.swift            quiet toggle
│       │   ├── FLSectionLabel.swift    sentence-case group header
│       │   ├── FLHairlineRow.swift     the row device
│       │   ├── FLEmptyLoadingLine.swift one thin indeterminate line (no skeletons)
│       │   ├── FLFitMeter.swift        m squares / n filled
│       │   ├── FLQuantityRow.swift     ingredient line, three states
│       │   ├── FLTimerTile.swift       cook timer, linearly depleting ring
│       │   ├── FLCookCard.swift        dish card: photo/none, note-as-quote, fit meter
│       │   └── FLTasteSentence.swift   correctable judgement
│       ├── Tests/FLDesignSystemTests/RenderTests.swift   dual-platform render matrix
│       ├── Renders/.gitkeep     conventional PNG output dir
│       └── README.md            component/token reference tables
├── ci/pending-workflows/design-system-renders.yml   HELD macOS render workflow
├── tools/contrast-check.py          WCAG ratio calculator used for the captured claims
├── project.yml.hook.md          exact diff wiring render tests into FridgeLuckTests
├── captures/
│   ├── FLDesignTokens-build-test.log        20 tests, 0 failures (initial F-only delivery)
│   ├── FLDesignTokens-extended-test.log     27 tests, 0 failures (with H/P directions)
│   └── FLDesignSystem-linux-build.log  build + 0-test pass (empty module by design)
└── README.md                    this file
```

## Verification (captured, this sandbox, Linux x86_64, Swift 6.4)

- **FLDesignTokens**: `swift build && swift test` — **Executed 27 tests, 0
  failures** (`captures/FLDesignTokens-extended-test.log`; the F-only baseline
  run is `captures/FLDesignTokens-build-test.log`). Covers the direction
  doc's WCAG claims within 0.1 (note: ink/paper computes to **17.44:1**; the
  doc says 17:1 — the test asserts 17.4 and records the discrepancy for the
  PR body), missing-role rejection, hex round-trip, radius/motion invariants.
- **Direction extensions (H + P)**: every pair the direction docs document
  is asserted within 0.1 — H's `contrast-table.md` contributes **42 rows**
  (13 per mode plus the accent-button-label and cook photo rows), P's §5
  contributes **64 rows** (56 text + 8 non-text). Note for the PR body: H's
  DIRECTION.md tally sentence says "53 text + 8 non-text pairs", but its own
  generator's table prints exactly these 42; the suite asserts the table and
  the tally sentence is flagged for correction. Also covered: the four
  adjusted P text hexes verbatim (#6B6054 / #A35131 / #5F6E53 / #7C5C30),
  the ten-role base-palette bridge for all six direction palettes (an H/P
  swap feeds FLDesignSystem unchanged), theme-swappable layout tokens (3:2
  photo frames, 40% height cap) on Theme/DirectionH/DirectionP, and H's
  linen-tinted kitchen pills (`pillIdle` #E9DCC3 / `pillGone` #DFD3BC light,
  #39332B / #332E26 dark — package-defined values, tested as fills ≥4.5 ink
  text and ≥1.15 as a shape against both grounds, idle lighter than gone).
- **FLDesignSystem**: `swift build && swift test` — build green, suite empty
  (`captures/FLDesignSystem-linux-build.log`). Every source file is guarded
  `#if canImport(UIKit) || canImport(AppKit)`, so Linux compiles an
  intentionally empty module; this proves the guards + manifest are sound.
  **Real compilation of the SwiftUI sources is deferred to macOS/iOS** — it
  cannot run in this sandbox and is the delivery's one unverified frontier.
  The render tests ride the existing iOS CI once `project.yml.hook.md` is
  applied; the macOS contact-sheet workflow is staged, not installed.

## Integration path (all gated on approval, none executed here)

1. Move `packages/` into the repo on the design branch.
2. Apply the three insertions from `project.yml.hook.md` to `project.yml`
   (local packages, test-target sources, test-target dependencies).
3. iOS CI regenerates the project and runs the render matrix in the simulator.
4. On approval, adopt `ci/pending-workflows/design-system-renders.yml` as
   `.github/workflows/design-system-renders.yml` for reviewable PNG artifacts.
5. On any Mac: `FL_RENDERS_DIR=./Renders swift test` inside FLDesignSystem
   produces the per-state PNGs and one `contact-<component>.png` per component.
