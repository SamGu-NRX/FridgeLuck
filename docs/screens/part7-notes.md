# Part 7 — cross-screen polish and the render matrix

Part 7 closes the UI-polish workstream (suite F, PLAN.md) with a
consistency audit across all twelve screen modules, fixes for what it
found, a cross-screen raw-source lint suite, and the H/P render matrix.
No screen was redesigned; every change below repairs a concrete
inconsistency between sibling screens, and each fix is pinned so it
cannot regress.

## Method

Read every Sources file, every lint test, the direction-H/P mocks, and
Parts 2–6 notes side by side, asking one question per axis: do sibling
screens in the same family agree — spacing rhythm, action placement,
photo treatment, state coverage, heading hierarchy, saved-food grammar?
Findings were fixed only where two screens of the same family disagreed
without a documented reason; the delta is in `git diff` (the lead owns
git), with the rationale here.

## Findings and fixes

### 1. Photo geometry was re-derived per screen (drift risk)

The 3:2-ratio / 40%-cap rule lived in `PhotoLayoutRule`, but each hero
then re-derived and re-capped the height inside its own `.frame`:

- **Double cap.** Tonight, Recipe, and Tour called
  `PhotoLayoutRule.photoFrameHeight` *and* wrapped the result in
  `min(…, PhotoLayoutRule.maxPhotoPortionOfScreen)` — a cap applied
  twice. Removed the second cap; the rule owns it.
- **Fixed heights.** Tour's card photo drew a hard `112`; Recipe's step
  photos used `UIScreen.main.bounds.width * 2/3`.
  Both now go through `PhotoLayoutRule`.
- **Raw ratio literals.** Table's card photo and Recipe's step photos
  spelled `3.0/2.0` inline instead of `PhotoLayoutRule.recipeRatio`.

`PhotoLayoutRule` gained the shared derivation (`referenceScreenWidth`
300 × `referenceScreenHeight` 852 → `heroIdealHeight` 200), and
`SupportTests` pins both the 3:2 reference ideal and the single
screen-height cap. The chosen reading: the 40% cap governs screen-top
heroes (its purpose is first-paint action visibility); in-card photos
follow the 3:2 ratio without the screen cap.

### 2. Explore was the only primary screen with no title

Every mock (H and P) and the Part 3 notes give Explore a plain
"Explore" h1; the view had none. Added the shared `FLTitleHeader`
(28/4, standard bold, header trait, `fl.explore.title`). This is the
one identifier Part 7 adds — `a11y-identifiers.md` records it.

### 3. Screen titles were invisible to VoiceOver's rotor

Titles were plain text — no `.isHeader` trait — so VoiceOver users
could not jump between sections. Every screen-title element across all
modules now carries `.accessibilityAddTraits(.isHeader)`, including the
alternate state titles (Tonight's states, Kitchen's, LeChef's) and the
new Explore title. `Part7RawSourceLintTests` pins the trait per screen
file. Native VoiceOver behaviour remains **UNVERIFIED-NATIVE** (source-
level only).

### 4. Part 6 screens used a different scroll rhythm

The family rhythm is 16 top / 24 bottom of scroll content. The Part 6
roots used 8/28/32. Progress, Profile, Quests, and Explore now share
16/24; the lint pins the root spacing grammar per screen file.

### 5. Taste's evidence tag broke the capsule tag family

Every other screen draws passive tags with `Capsule().fill(yolkSoft)`
+ 8/4 padding (hence "capsule tag family" in the mocks). Taste's
evidence tag drew an 8-radius rounded rectangle with 12/6 padding.
Aligned to the shared Capsule grammar; the lint pins both Tonight's and
Taste's tag construction.

### 6. Kitchen's status glyph disagreed with the quantity-row glyph

Kitchen's confirmed-state dot and unconfirmed dash used `stroke(lineWidth: 2)`
and a `[3, 3]` dash; the shared `FLQuantityRow` grammar is a filled
square + `[2, 2]` dash. Aligned Kitchen to the shared grammar so the
two glyphs read identically; the lint pins the construction.

### 7. Scan drew its own loading line

The analysing state hand-drew a 1pt yolk `Rectangle` with its own
reduce-motion branch. Replaced with `FLEmptyLoadingLine` (identical
render, shared motion + a11y behaviour, `fl.scan.progressLine`
identifier preserved). The lint requires the shared line for every
loading state and bans raw progress rectangles in the Sources tree.

### 8. Tour's card padding stood outside the family

The tour card used 20 padding; every other card surface uses 16.
Aligned to 16 (a numeric-radius ban companion: paddings are pinned by
the root-spacing test, not a value ban — this was a one-line alignment).

## Deliberately left alone (documented exemptions)

- **LeChef's 3:2 viewfinder** is the camera framing ratio, not a photo
  area — it predates the photo rule and belongs to the screen's
  contract (Part 5). Exempt from the photo-geometry lint with that
  comment in-file.
- **Table's "food saved" copy** is host-verbatim text, not a formatted
  count — `FLSavedFoodLine` is for computed counts. The saved-food lint
  pins exactly that boundary: every *formatted* saved-food number goes
  through the shared line.
- **Loading/error vocabulary differs by family on purpose**: feed-style
  surfaces (Tonight, Explore) share `FLEmptyLoadingLine`; document
  surfaces (Recipe, Table detail) load nothing async; Scan, Taste, and
  Kitchen failures are specific escapes ("Save failed", camera
  refusal), not generic error copy. The audit found no two siblings of
  the same family disagreeing here, so nothing changed.
- **LeChef's 1–5 rating scale** keeps its locally pinned constants
  rather than a cross-module dependency for one number.

## The Part 7 cross-screen lint

`Tests/FLScreensLintTests/Part7RawSourceLintTests.swift` — 13 tests
that read the Sources tree as text and assert the invariants ACROSS all
modules in one place, so a future screen cannot quietly break
discipline:

1. every screen view file takes colour through `Theme.swiftColor` and
   type through `.flType`, and files that draw shapes take radii
   through the closed `Radius` set;
2. no file outside `FLRenderPaletteMapping`/`Theme` names a direction
   (`DirectionH`/`DirectionP`) — the H↔P swap stays a theme swap;
3. no screen file carries a numeric `cornerRadius` literal;
4. photo geometry appears only through `PhotoLayoutRule` (no raw 3:2
   literals, no `UIScreen.main` sizing, no second cap);
5. hero photos use the one shared `heroIdealHeight` derivation;
6. in-card photos use the shared ratio;
7. scroll roots share the 16/24 family rhythm;
8. screen titles are marked as accessibility headers;
9. Explore carries its mock-matched title;
10. passive tags belong to the Capsule family;
11. no screen file bakes a numeric corner radius into a shape call;
12. Kitchen's status glyph matches the quantity-row grammar;
13. loading states use the shared `FLEmptyLoadingLine`; saved-food
    formatting goes through `FLSavedFoodLine` (Table's host-verbatim
    copy is the pinned exception).

## The render matrix

`docs/screens/render-matrix.md` is the review document: every screen
state family × H/P × light/dark/cook, each cell carrying its two
statuses — **L** (the colour layer: token tables, mapping, contrast —
pinned by Linux tests) and **N** (**UNVERIFIED-NATIVE**: the rendered
appearance needs the held render workflow `ci/pending-workflows/
screens-renders.yml`) — plus the mock that each cell will be reviewed
against when the workflow runs. Every cell is L today; every cell is N
by design; nothing in Part 7 claims a render that never happened.

## Verification status

- `FLDesignTokens`: 27 tests, 0 failures (unchanged by Part 7).
- `FLScreens`: baseline intact plus the 15 new tests (13 lint + 2
  Support), zero failures — exact counts in the task report.
- `FLDesignSystem`: still builds on Linux.
- Native SwiftUI compilation, VoiceOver behaviour, and every rendered
  cell of the matrix: **UNVERIFIED-NATIVE** (no Apple toolchain here).
- The render workflow stays held; nothing in Part 7 installs it.
