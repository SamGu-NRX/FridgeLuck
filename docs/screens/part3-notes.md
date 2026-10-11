# Part 3 delivery: Explore feed, beta Tables, Recipe detail

Continuation of `tonight-kitchen.md` (Part 2, branch
`overhaul/screens-tonight-kitchen` at `f25fe74`). Same ground rules: every
colour through `Theme.swiftColor`, every type through `.flType`, every
radius through `Radius`, every spacing through `Theme.layout`
(`LayoutTokens`), photo geometry only through `PhotoLayoutRule` — the
lint suite asserts this mechanically for all three new view files.
Nothing hard-coded; the screens build against `FLRenderPaletteMapping` /
`Theme`, never a direction-specific type, so Direction P is a theme
swap, not a variant of the screens.

## Module split

- **`Sources/FLExplore`** — the Explore feed **and** Table (state,
  intent, reducer, views). Reason: Table renders INSIDE Explore behind
  its beta flag (`fl.explore.tableEntry` → `TableView`, no tab), shares
  the fit vocabulary and provenance lines with the feed, and the mock
  treats it as one context. A separate module would have needed a
  shared-values home anyway — the feed is the home.
- **`Sources/FLRecipe`** — the Recipe document, its own small module.
  Reason: Recipe is reached from three places (Tonight, Explore rows,
  Tables) and nothing in it belongs to the feed; its test surface
  (scaling, step flow, record sheet) stands alone.

Both split the Part 2 way: Foundation-only view state + typed intents +
reducers (Linux-tested), SwiftUI views Apple-gated per `#if canImport`
exactly as `FLTonight`/`FLKitchen` gate them. Services still arrive
through the same host seams — no service type appears in state code.

## Explore — adopted vs. adapted

**Adopted from `direction-h/explore.html`:** the ranked band structure
("Made for your fridge" → "Can cook now" → "One swap away"; a fourth,
"More to cook", catches rows the mock never draws so nothing silently
disappears); the fit line in mono on every row; "cooked by N people"
only at ≥ 10 distinct cooks from opted-in data, "Be the first to cook
this" under that; the search + filter chips with the zero-hits state
that states the query and offers "Clear" without dropping the query;
"In review — only you can see it" with "Withdraw" on the author's own
pending row; the offline "As of HH:MM" provenance line over the last
valid list.

**Adapted:** the mock's masonry collage becomes a native
`List`/sectioned stack (pod layout, dynamic type, no fixed cells); the
mock's decorative gradient header becomes a plain large-title header on
the token background; the mock's inline share pills become a menu on
the row (matching Kitchen's edit pattern, not web hover affordances).

## Table — adopted vs. adapted

**Adopted from `direction-h/table.html`:** the quiet "Community tables"
header with the BETA line; the entry row lives in Explore (per the
round decision — Table is not a tab) and renders only while the beta
flag is on, in state, not in view logic; cook cards with the week
summary, the derived fit action ("Cook it at 2" from the recorded
servings — never re-derived from memory in the view), offline notice
with retry, the weekly challenge ("Count me in"), and cook notes.

**Adapted — the share sheet is the big one:** the mock shows a share
preview with exactly the fields that leave the phone. The screen cannot
invent privacy, so `TableViewState.SharePreview` is a separate value
built only from explicitly shareable fields; the view renders
`shareFields` verbatim, and the lint suite asserts the type declares
only those fields. The mock's photo-frame-on-a-card is adapted to
3:2 `PhotoLayoutRule` framing (the design-system `FLCookCard` frame is
1:1 and unused here); the mock's horizontal card rail becomes a stack
below the fold.

## Recipe — adopted vs. adapted

**Adopted from `direction-h/recipe.html`:** hero (3:2, capped at 40% of
container height), the byline + fit/minutes stats line, the servings
stepper with ingredients rescaled by the state layer (bounded 1–12;
quantity strings derived by the state, including swap notes), the
"no X? try Y" swap lines, the method step flow ("Step 2 of 6" with
Next / Skip to the end), cook notes & tips, related recipes, and the
record sheet (1–5 stars, "Cooked it differently?", the privacy line,
Save / Share to a table — never auto-shared).

**Adapted:** the mock's sticky glass footer becomes a native
`safeAreaInset` bar for the primary "Cook for N" action; the record
sheet is a native `sheet` with `presentationDetents`; the mock's
scroll-linked hero parallax is dropped (no UIKit custom transition —
flagged below).

## Direction P coverage

Both variants resolve through `FLRenderPaletteMapping`: `.h` and `.p`
each map to their real FLDesignTokens table (`DirectionH.swift` /
`DirectionP.swift`, `isProvisional` false since Part 2). No screen type
mentions a direction; the same `ExploreViews`/`TableViews`/
`RecipeViews` render either theme from `Theme.swiftColor(_, in: scheme)`
+ `.flType` + `Radius` + `Theme.layout` alone. The Part 2 mapping tests
(`SupportTests`, 12) keep both tables resolving; the Part 3 state tests
are palette-agnostic by construction. What the mocks show for P (pill
chrome, mono-only voice) stays a token-table difference — no screen
branches on it, per the round constraints.

## What the SwiftUI screens cannot yet do natively

- **Rendered verification:** the views are Apple-gated and compile only
  on an Apple toolchain; this delivery proves the Foundation state,
  reducers, lint contracts and Linux package graph. First-paint on
  device (Liquid Glass material behaviour, dynamic-type reflow) is
  unverified until the host builds the app target.
- **Live photos:** mocks ship baked-in photography; the screens frame
  placeholder space through `PhotoLayoutRule` until the host supplies
  real images.
- **Scroll-linked hero parallax (Recipe)** — dropped, not adapted; the
  mock's effect needs UIKit transitions outside this layer's seams.
- **Horizontal card rail (Table)** — replaced by a stack; a native rail
  wants `ScrollView` paging measurements this layer cannot test on
  Linux.

## Verification (measured this delivery)

- `packages/FLDesignTokens`: `swift test` → **27 tests, 0 failures**
  (unchanged).
- `packages/FLScreens`: `swift test` → **120 tests, 0 failures** —
  Part 2 baseline 47 intact (TonightState 17, Lint 3, Support 12,
  Kitchen 15) plus new: FLFitSummaryTests 12, ExploreStateTests 21,
  TableStateTests 16, RecipeStateTests 18, Part3RawSourceLintTests 6
  (per-class counts from the run log).
- `packages/FLDesignSystem`: `swift build` on Linux → success.
- `docs/screens/a11y-identifiers.md`: extended (still a PROPOSAL) with
  `fl.explore.*`, `fl.table.*`, `fl.recipe.*` tables drawn from the
  identifiers the views actually set.
