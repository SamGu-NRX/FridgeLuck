# FLDesignSystem

FridgeLuck's SwiftUI component package. Values come from **FLDesignTokens**
(the Foundation-only package: colour, type, density, radii, motion, haptics);
this package turns them into views. Components are value-driven plain SwiftUI —
no view models, no services, no networking.

Everything here is guarded `#if canImport(UIKit) || canImport(AppKit)`.
On Linux, `swift build` succeeds with an intentionally empty module; real
compilation happens on macOS/iOS (repo CI on macos-26).

**Platform floor:** iOS 26, macOS 15. macOS 15 is the lowest version Xcode 26
can build this package for that carries everything it uses (ImageRenderer,
`.spring(duration:bounce:)`, `.monospaced()` on Font, accessibility Dynamic
Type sizes). Bump to macOS 26 only when the app target standardises on it.

## Scheme

Every component reads its palette from `\.flScheme` (an environment value:
`FLScheme` = `ColorScheme` from the tokens — `paper`, `hob`, `dark`,
defaulting to `paper`). Set it once at a screen's root:

```swift
CookModeScreen().flScheme(.hob)
```

`.flScheme` also sets SwiftUI's own `\.colorScheme` (`hob` and `dark` are
dark appearances) so system controls agree with the palette.

## Type

`View.flType(_ role: TypeRole)` applies a role's system font — scaled by
Dynamic Type around a role-specific anchor, monospaced on the numeral roles
(`timer`, `fitCount`, `quantity`, `evidence`), with the role's line height.
Numerals scale to the accessibility sizes. `Text.flTracking(_:)` adds letter
tracking where the role carries it (SwiftUI kerning is Text-only; it applies
at the role's nominal size).

## Components

### The five identity components

| Component | Purpose | Tokens used | States | Accessibility |
|---|---|---|---|---|
| `FLFitMeter` | The app's promise made visible: m squares, n filled, mono count, optional swaps | `ink` (filled), `rule2` (hollow), `fitCount` (mono 17), `secondary` | any have/total; swaps nil/1/n | One element reading "9 of 10, 1 swap"; squares hidden from VoiceOver |
| `FLQuantityRow` | Ingredient line: state square, name, mono quantity | `body`, `quantity` (mono 15), `rule` (hairline), `ink`/`ink2`/`rule2`; 44 pt row | `have` (filled), `missing` (hollow), `unconfirmed` (dashed) | Single element reading "name, quantity, state"; optional action via `FLHairlineRow` button |
| `FLTimerTile` | Cook-mode timer: ring depleting linearly | radius `card` (14), hob palette (`bg`, `ink2`, `ink3`, `yolk`), `timer` (mono 56), `caption`; press 0.97/120 ms | running / paused ("Paused" caption, digits at 70% opacity) | One element: label, spoken time, paused state; hint names pause/remove |
| `FLCookCard` | A cooked dish: photo 1:1 or none, name, who · when, note as quote, viewer's fit meter, one button | radius `card`, `body` (semibold name), `caption`, `ink` quote rule, hairline `rule` border, `FLFitMeter`, `FLButton` | with/without photo, with/without note | Note combined as "Note: …"; no gradient scrim or white text on photos |
| `FLTasteSentence` | The correctable judgement: sentence, evidence count, Right / Wrong | `body`, `evidence` (mono 13), small outlined buttons (`rule2` stroke, radius `buttonOrChip`) | open; wrong → greys (75% opacity, ink2), "Won't use this" + Undo | Buttons are real buttons; correction always recoverable |

### Structure and controls

| Component | Purpose | Tokens used | States | Accessibility |
|---|---|---|---|---|
| `FLButton` | The only button: primary (ink filled) / secondary (outlined) / text | `ink`/`bg`, `rule2` outline, `body`, radius `buttonOrChip` (10), height = `deciding.actionClearance` (48), press 0.97/120 ms | three kinds; optional `HapticRole` pairing | Label is caller's verb copy; `FLButtonStyle` keeps press feedback under reduce motion |
| `FLChip` | Quiet toggle for filters/tags | radius `buttonOrChip`, selected `yolkSoft` bg + `yolkInk` text; unselected `rule2` + `ink2` | selected / not; `lightConfirm` haptic | `.isSelected` trait |
| `FLSectionLabel` | Group header | `sectionLabel` (13/16 w600), `ink2`, `.isHeader` | — | Sentence case is a rule: never uppercased, and callers pass sentence-case copy |
| `FLHairlineRow` | The row device: ≥44 pt, 1 pt `rule` bottom line, whole row presses | `rule`, dense row metrics (44/12) | tappable / static | One actionable element when tappable |
| `FLEmptyLoadingLine` | Loading: one thin indeterminate line. NO shimmer, NO skeletons | `rule2` track, `ink3` segment, `fade` token | sweeping (linear, transform-only) / reduced motion (static, dimmed) / idle (full line) | Label "Loading" / "Empty" |

## Motion

`Animation.fl(_ token: MotionToken)` exposes the five named motions
(`snap` 0.22/0, `move` 0.34/0.12, `settle` 0.50/0.22, `fade` 0.15 ease-out,
`none`). Press feedback (scale 0.97 over 120 ms, back with snap) lives in
`FLButtonStyle` — the system's only button style — and rows adopt it by being
buttons. Under reduce motion, transforms become 150 ms opacity fades
(`Theme.reducedMotionFadeMs`), stagger goes to 0 — but the press scale stays
(it is the tap confirmation) and the timer ring keeps moving (it is
information). Only transform and opacity animate anywhere in this package.

## Haptics

`FLHaptics.fire(_ role: HapticRole)` maps the token roles to platform
generators (UIKit impact styles light/medium/rigid; one coarse NSHapticFeedbackManager
hit on macOS). Components accept an optional `HapticRole` on their
initializers; the role table's surfaces (`confirm row`, `chip`,
`add-to-kitchen`, `cook-complete`, `timer finished`) say where each belongs.

## Render tests

`Tests/FLDesignSystemTests/RenderTests.swift` renders every component in its
relevant states — paper, hob, dark, accessibility XXL
(`.dynamicTypeSize(.accessibility5)`), paused / reduced-motion, and the
loading-line variants — through SwiftUI `ImageRenderer`, writing 2× PNGs into
`FL_RENDERS_DIR` (created when missing; tmp fallback), then assembles one
`contact-<component>.png` per component via `makeContactSheets()`.
They are macOS-only (guarded); on Linux the suite is empty and passes.

```sh
FL_RENDERS_DIR=./Renders swift test    # macOS — writes PNGs into Renders/
```

`Renders/` is the conventional checkout location (`.gitkeep` keeps it).
