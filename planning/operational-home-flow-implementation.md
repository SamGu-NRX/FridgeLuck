# Operational Home flow — implementation record

This document describes the non-visual core that draft PR #85 added for
`operational-home-flow-spec.md`. The redesigned Home UI can be built on top of it
unchanged: the gate and every future section read the same state derivation, the
same read result, and never touch tutorial progress or coordinator internals.

## The five states

`HomeFlowState` (in `apps/ios/Feature/Home/HomeFlowModels.swift`) is the single
source of truth for what Home is showing:

| State | Meaning | Enters when |
|---|---|---|
| `.error` | The flow could not read the world at all | Inputs are `nil` — a cold-start load failure (the view's nil-snapshot branch owns this; the map never returns it for non-nil inputs) |
| `.cooking(HomeCookContext?)` | A cook is live in the Assistant | A non-nil cook context is supplied by the view |
| `.returning` | A cook with history | `totalMealsCooked >= 1` |
| `.emptyNew` | Onboarded, empty kitchen, no meals cooked | Tour-complete or not, the kitchen is genuinely empty |
| `.partlyStocked` | Onboarded, fridge has stock, no meals cooked yet | Stock exists and no meals yet |

Precedence, highest first: **error → cooking → returning → emptyNew →
partlyStocked**. A cooking session outranks everything; history outranks the
empty-new onboarding path.

Binding rules pinned by tests:

- **Unknown expiry is `nil`, never zero.** A lot with no known expiry reads back
  with `daysUntilExpiry == nil` and `earliestExpiresAt == nil`. The writer
  (`InventoryRepository.addLot`) derives a shelf-life date when it can (a fridge
  lot with no profile row gets +7 days); genuinely unknown expiry exists only via
  `location: .unknown` with no shelf-life profile — and then it is `nil` all the
  way to the UI. See `testLotWithUnknownExpiryKeepsNilDaysUntilExpiry` and
  `testFridgeLotWithoutExpiryDerivesSevenDayShelfLife`.
- **Tutorial progress is not an input.** `HomeFlowInputs` has no tutorial field;
  the compile-time surface makes it impossible for the state derivation to read
  learning progress. The view decides what an `.emptyNew` kitchen displays
  (quest cards vs dashboard) — that is presentation, not state.
- **The cooking state reads only the surfaced Assistant context.**
  `HomeCookContext` is built in the view from
  `LiveAssistantCoordinator.matchedRecipeContext` (the surfaced value type), never
  from coordinator internals.

## Two derivation paths, one set of rules

1. **Canonical:** `HomeFlowStateMap.state(inputs:cookContext:)` — the full
   `HomeFlowInputs` (onboarding, active items, use-soon, meal counts, journal,
   macros, streak, profile, recommendations). This is the redesigned Home's entry
   point: sections should read the same `HomeFlowInputs`.
2. **Fork projection:** `HomeFlowStateMap.state(from:cookContext:)` — the same
   precedence rules evaluated over the `HomeDashboardSnapshot` the shipped
   sections already consume (`hasOnboarded`, `ingredientCount`,
   `totalMealsCooked`) plus the view-supplied cook context. It exists so the
   shipped gate switches on the map without re-plumbing the sections, and it
   never reports `.error` (a non-nil snapshot means the read pass succeeded).
   Agreement between the two paths is tested for emptyNew, partlyStocked, and
   returning.

## The read layer

`HomeFlowReadModel` (in `HomeFlowReadModel.swift`) makes **one pass** over the
public repository APIs — the same reads, in the same order, the dashboard view
model always made — and returns `HomeFlowReadResult`:

```swift
struct HomeFlowReadResult {
  let inputs: HomeFlowInputs          // feeds the state map
  let snapshot: HomeDashboardSnapshot // feeds today's sections
}
```

Both shapes come from the same reads, so the gate and the sections can never
disagree. Recommendation assembly reuses the existing policy chain
(`RecommendationPolicy.effectiveIngredientIDs(from:)` → `findMakeable` →
`findNearMatch`).

`HomeLoadGeneration` is the pure staleness guard: each load takes a generation
number and applies only if it is still current, so a slow early load can never
clobber a newer one. The guard is a value type tested on Linux.

`HomeFlowViewModel` (`HomeFlowViewModel.swift`, app target only — `ObservableObject`
does not exist on Linux) is a thin shell: published `inputs`, `snapshot`,
`cookContext`, `isLoading`, `errorMessage`; the guarded load; and the same GRDB
live observers (cooking history, inventory) Home has always used. A failed refresh
mid-flight keeps the last good inputs on screen; only a cold-start failure lands
in the error state.

## How the shipped view wires it

`HomeDashboardView.body` resolves
`HomeFlowStateMap.state(from: snapshot, cookContext: viewSuppliedContext)` and
switches: `.emptyNew` shows the tutorial home for an incomplete tour and the
graduated dashboard otherwise; `.partlyStocked`, `.returning`, and `.cooking`
show the graduated dashboard; `.error` (unreachable with a non-nil snapshot) keeps
the existing error state for switch totality. ContentView.swift and the Home init
surface are byte-identical — the change is the fork and nothing else.

## Verification

`apps/ios/Tools/home-flow-check` mirrors `historical-nutrition-check`:
`Scripts/refresh.sh` copies the real production sources (repositories, services,
models — no app targets, no SwiftUI) into the ignored `Sources/HomeFlowCheck/Real/`,
and the tests drive them against real migrated GRDB databases.

```sh
swift test --package-path apps/ios/Tools/home-flow-check
```

Coverage at the time of writing: 38 tests — 23 state-map (every state, every
precedence overlap, every primary action, the cook-context transition seam, the
no-tutorial-input contract), 6 fork-projection (including agreement with the
canonical path and never-error), 9 read-model (real-database cold start, stocked
kitchen, unknown-expiry nil, fridge shelf-life derivation, use-soon surfacing,
pre-onboarding hiding, generation guard, read→gate seam).

Native-only checks — rendering, Dynamic Type, VoiceOver, and any XCUITest run —
are **UNVERIFIED-NATIVE** (this work ran on Linux; no simulator or device).
