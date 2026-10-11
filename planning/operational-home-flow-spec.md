# FL4 · Operational Home flow — state map, read model, gate replacement

> **Status: SPEC ONLY — implementation not started.** This document is the saved spec
> (Blueprint `art_bQYeOGMW`, saved `7722fa1f`). The execution plan (one coder milestone
> sequence + human review) was proposed but never approved before workspace retirement,
> so no Swift code, no `home-flow-check` package, and no implementation commits exist.
> Everything below is ready-to-execute design; the Handoff section of the PR carries
> next steps.

Home shows the kitchen whenever real data exists. The `tutorialProgress.isComplete`
dashboard gate is replaced by a five-state operational map built from actual public
repository outputs; learning becomes an optional, restartable practice panel, and
`ContentView` plus the spotlight contract stay untouched.

## Problem

Home should help someone use the kitchen they just confirmed — not force them through a
demo before their dashboard appears.

**Load-bearing assumption.** The tutorial gate — not navigation or data availability — is
what keeps a new user off their dashboard. Confirmed by one check: the base branch's
`ContentView` shows the Home stack by default the moment onboarding closes, so the
`tutorialProgress.isComplete` fork inside `HomeDashboardView.body` is the last wall
(art_574HY2JT §1.1). If a future build changes tab defaults, this spec's gate
replacement alone stops being sufficient.

- **Current signal.** `HomeDashboardView.body` forks on `TutorialProgress.isComplete` —
  a value derived from four tutorial quests persisted under the `@AppStorage` key
  `"tutorialProgressStorage"`. Until every quest is done (or the tour is skipped), the
  user sees quest cards instead of a kitchen dashboard. The same flag also gates the
  Progress tab through `AppFlowPolicy.progressEntryRoute` in `ContentView`. Learning
  completion and data existence are conflated: someone who stocked their fridge but
  skipped the tour gets neither the tour nor their data.
- **Desired outcome.** Home renders an operational dashboard whenever real data exists,
  tuned to one of five states — **empty/new, partly stocked, cooking, returning,
  error** — derived from actual public repository outputs. Tutorial practice survives as
  an optional, restartable panel that never blocks the dashboard and never mutates real
  Kitchen or history data.

**Scope boundary.** Read-only for this task: `ContentView.swift`, `AppDependencies.swift`,
`SpotlightTutorialOverlay.swift`, `SpotlightCoordinator.swift`, core query/migration/
logging files, Kitchen/Inventory code, weekly-plan and journal-correction code.
Weekly-plan and persisted Active Cook surfaces are out of scope — no persisted source
for either exists on this branch.

## What the code shows today

Two read-only research passes at base HEAD `6ee55e7e` ground every decision; full
findings live in Obvious artifacts `art_574HY2JT` (Home surface + app wiring) and
`art_R7TpjWAJ` (data layer, Tools, prior proposals).

| Read (path · symbol) | Learned | Shaped the design |
|---|---|---|
| `Feature/Home/HomeDashboardView.swift` · `body` fork, `TutorialProgress` over `@AppStorage("tutorialProgressStorage")` | The tutorial/dashboard split is one derived value forked in exactly one UI place; `HomeResetFooterSection` sits below both branches (art_574HY2JT §1.1). | Replacing the fork inside the Home-owned file is sufficient; reset/skip semantics stay. |
| `App/ContentView.swift` · Home call site | Home is constructed with a 13-member surface: `deps` plus 11 closures (`onScan`, `onQuestCTA`, `onDemoMode`, `onCompleteProfile`, `onOpenRecommendation`, `onOpenAssistant`, `onOpenVirtualFridge`, `onSwitchToKitchen`, `onSwitchToProgress`, `onReset`, `onOnboardingSpotlightWillPresent`), `prefersAcceleratedOnboardingSpotlight`, `spotlightCoordinator` (art_574HY2JT §2). | The init signature is preserved byte-for-byte; `ContentView` never changes. |
| `Feature/Home/SpotlightCoordinator.swift` · `anchorsReady(for:)`; `SpotlightModels.swift` tours | Tours present only when every required anchor rect is non-empty; Home publishes `"progressView"`, `"quest_<rawValue>"`, `"myRhythm"`, `"liveAssistantEntry"` and `ContentView` renders the overlay (art_574HY2JT §3). | The new presentation keeps publishing all four anchors whenever their content is on screen. |
| `TutorialQuestModels.swift` · consumers | Also consumed by `ContentView`, `DemoModeView`, `IngredientReviewView`, `RecipeResultsView`, and Settings replay (art_574HY2JT §1.1). | The types and storage key stay; only the dashboard gate goes. Quest completion keeps writing, so Progress-tab gating in `ContentView` is untouched. |
| Repository read APIs · `InventoryRepository`, `UserDataRepository`, `PersonalizationService`, `RecipeRepository`, `RecommendationPolicy` | The exact public outputs Home already loads: `fetchAllActiveItems()`, `useSoonSuggestions(withinDays:limit:)`, snapshot-backed `cookingJournal`/`todayMacros`/`mealsCooked(lastDays:)`/`hasCompletedOnboarding()`, `currentStreak()`/`weekActivity()`, `findMakeable`/`findNearMatch` over `effectiveIngredientIDs` (art_R7TpjWAJ §1.1–1.5, §1.7). | These are the read model's inputs — nothing invented. Freshness basis is expiry-date fields (`daysUntilExpiry`/`daysRemaining`); unknown expiry is nil, never zero. |
| Provenance conventions · `InventoryActiveItem.mostRecentSource`/`hasEstimatedQuantity`; `ProgressSnapshot`; v20 snapshot nullability | Unknown-vs-zero is carried by optionals and enums at the model boundary; provenance is a labeled field, and readiness gaps throw loudly (art_R7TpjWAJ §1.1, §1.6, §2). | The read model keeps unknowns optional and never defaults a missing fact to a friendly zero. |
| Cooking state · `CookingGuideStateTransitions`; planning/ "Active Cook" proposal | No persisted active-cook record exists on this branch; progress is view-local sets, and the resumable Active Cook surface is a planning proposal only (art_R7TpjWAJ §1.2, §4.1). | The `cooking` state derives from an explicitly injected cook context (Live Assistant coordinator state surfaced as a value) — documented as the only live source, not invented from repositories. |
| `Tools/historical-nutrition-check` · `Scripts/refresh.sh`, fixtures, `Package.swift` | Linux-safe check package: copies 16 real production sources into a gitignored `Real/`, compiles them against GRDB, runs XCTest on per-test UUID SQLite queues with migrations pinned via `migrate(upTo:)`, fixed literal timestamps, and `bitPattern`-exact compares. Baseline re-run: 12/12 pass (art_R7TpjWAJ §3). | `home-flow-check` clones this proven pattern for Home's files; the weekly-plan-check symlink variant is the noted alternative (art_R7TpjWAJ §3). |
| Prior Home proposals · planning/ §1 "Home"; open PRs #61/#62 | The decision surface Home should hold — primary recommendation, use-soon action, active cook, daily nutrition context, fast fallbacks — and a conflict surface where same-base PRs already touch `ContentView.swift` (art_R7TpjWAJ §4.1, §4.3). | The state map composes that same decision surface; the PR records expected conflicts with the older proposals. |
| `DesignSystem/` · `AppTheme`, component set | Warm-editorial tokens (`AppTheme` colors/Space/Radius/Shadow/Typography/`.flPageBackground()`), `FLPrimaryButton`/`FLCard`/`FLSectionHeader`/`FLStatusPill`/`FLEmptyState`/`FLProgressRing`/`FLStreakBadge`/`FLStatDisplay`, per-site `reduceMotion` gating (art_574HY2JT §5). | The operational dashboard reuses these components and the established card recipe; no net-new primitives. |

## What we build

Four deliverables, all Home-owned. The state map is the contract everything else consumes.

### 1 · Typed state map — `Feature/Home/HomeFlowModels.swift` (new)

Inputs are exactly the public outputs Home already loads — no new queries, no invented
services. Freshness is expiry-date based (`daysUntilExpiry`/`daysRemaining`), with
unknown expiry representable as nil, following the `InventoryActiveItem` unknown-vs-zero
discipline (art_R7TpjWAJ §1.1).

```swift
// apps/ios/Feature/Home/HomeFlowModels.swift
// Inputs: exactly the public repository/service outputs HomeDashboardViewModel loads today
// (art_574HY2JT §1.1; art_R7TpjWAJ §1.7). Sendable value types; nothing UI- or GRDB-bound.

struct HomeFlowInputs: Sendable, Equatable {
    let hasCompletedOnboarding: Bool                  // UserDataRepository.hasCompletedOnboarding()
    let inventoryItems: [InventoryActiveItem]         // InventoryRepository.fetchAllActiveItems()
    let useSoon: [InventoryUseSoonSuggestion]         // SpoilageService.useSoonSuggestions(withinDays: 3, limit: 3)
    let totalMealsCooked: Int                         // UserDataRepository.totalMealsCooked()
    let mealsCookedLast7Days: Int                     // UserDataRepository.mealsCooked(lastDays: 7)
    let latestJournalEntry: CookingJournalEntry?      // UserDataRepository.cookingJournal(limit: 1)
    let todayMacros: MacroTotals                      // UserDataRepository.todayMacros() (zero = genuinely none logged)
    let currentStreak: Int                            // PersonalizationService.currentStreak()
    let weekActivity: [Bool]                          // PersonalizationService.weekActivity()
    let healthProfile: HealthProfile?                 // UserDataRepository.fetchHealthProfile(); nil pre-onboarding
    let primaryRecommendation: HomeRecommendation?    // findMakeable/findNearMatch via RecommendationPolicy.effectiveIngredientIDs
    let fallbackOptions: [HomeRecommendation]
}

/// The one live cooking signal on this branch. No persisted active-cook record exists
/// (art_R7TpjWAJ §1.2); the Live Assistant coordinator's context is surfaced as a plain
/// value by the view layer — the state map itself stays repository-pure.
struct HomeCookContext: Sendable, Equatable {
    let recipeName: String?
}

enum HomeFlowState: Equatable, Sendable {
    case emptyNew                      // kitchen confirmed, nothing stocked, no meals
    case partlyStocked                 // some stock, no meals yet
    case cooking(HomeCookContext?)     // live cook context present
    case returning                     // at least one meal cooked
    case error                         // load failed; retry path
}

enum HomeFlowPrimaryAction: Equatable, Sendable {
    case completeProfile               // → onCompleteProfile
    case scanKitchen                   // → onScan
    case cook(HomeRecommendation)      // → onOpenRecommendation
    case restock                       // → onOpenVirtualFridge
    case resumeCook                    // → onOpenAssistant
    case retry                         // → HomeFlowViewModel.retry()
}

/// Pure and total: identical inputs always map to the identical state.
/// Precedence: error > cooking > returning > stock states. `totalMealsCooked` is
/// durable evidence, so returning ranks above the empty-stock states.
enum HomeFlowStateMap {
    static func state(inputs: HomeFlowInputs?, cookContext: HomeCookContext?) -> HomeFlowState {
        guard let inputs else { return .error }
        if let cookContext { return .cooking(cookContext) }
        if inputs.totalMealsCooked > 0 { return .returning }
        if inputs.inventoryItems.isEmpty { return .emptyNew }
        return .partlyStocked
    }

    /// The action Home leads with, chosen from data — never a placeholder.
    static func primaryAction(for state: HomeFlowState, inputs: HomeFlowInputs?) -> HomeFlowPrimaryAction {
        switch state {
        case .error:
            return .retry
        case .cooking:
            return .resumeCook
        case .emptyNew:
            if inputs?.healthProfile == nil { return .completeProfile }
            return .scanKitchen
        case .partlyStocked:
            if let recipe = inputs?.primaryRecommendation { return .cook(recipe) }
            return .scanKitchen
        case .returning:
            guard let inputs else { return .retry }
            if inputs.inventoryItems.isEmpty { return .restock }
            if let recipe = inputs.primaryRecommendation { return .cook(recipe) }
            return .scanKitchen
        }
    }
}
```

Design notes. **Empty/new** covers both a pre-onboarding user (whose view is briefly
covered by the onboarding cover anyway) and a confirmed user with an empty fridge — the
setup strip distinguishes them by `healthProfile` and `hasCompletedOnboarding`.
**Use-soon** urgency stays a visible action card (expiry-date driven,
`onSwitchToKitchen`) rather than hijacking the primary slot — matching the planning
doc's "warning language → action language" intent without burying the recommendation
(art_R7TpjWAJ §4.1).

### 2 · Read model + view model — `Feature/Home/HomeFlowReadModel.swift` (new)

Narrow dependency injection at the boundary — the established `ProgressViewModel`
pattern (art_R7TpjWAJ §2) — so no `AppDependencies` change is needed and the whole read
layer compiles on Linux in the check package.

```swift
// apps/ios/Feature/Home/HomeFlowReadModel.swift
// Reads the same public APIs, in the same order, as HomeDashboardViewModel does today.

@MainActor
struct HomeFlowReadModel {
    let inventory: InventoryRepository
    let userData: UserDataRepository
    let personalization: PersonalizationService
    let spoilage: SpoilageService
    let recipes: RecipeRepository
    let ingredients: IngredientRepository

    /// One pass, one result. Recommendation assembly reuses the existing policy chain:
    /// RecommendationPolicy.effectiveIngredientIDs(from:) → findMakeable → findNearMatch
    /// → sharedRankingScore ordering for primary + fallbacks (art_R7TpjWAJ §1.5, §1.7).
    func load() throws -> HomeFlowInputs { /* same call sequence as today's load() */ }
}

@MainActor
final class HomeFlowViewModel: ObservableObject {
    @Published private(set) var inputs: HomeFlowInputs?
    @Published private(set) var cookContext: HomeCookContext?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loadGeneration = 0
    private var cancellables: [AnyDatabaseCancellable] = []

    init(readModel: HomeFlowReadModel)

    /// Generation-guarded: each request bumps `loadGeneration`; a completed load
    /// applies only if its generation is still current, so a stale GRDB-observer
    /// reload can never overwrite a newer one.
    func load() async
    func retry() async
    func updateCookContext(_ context: HomeCookContext?)   // fed from the coordinator, view-side
}
```

Live updates ride the same GRDB observers Home uses today
(`observeCookingHistoryChanges`, `observeInventoryChanges` — art_574HY2JT §1.1), each
triggering a generation-guarded reload. Failure keeps the last good inputs on screen
when a refresh fails mid-flight; a cold-start failure lands in `.error` with Retry.

### 3 · Presentation — the fork replaced inside `HomeDashboardView.swift` (owned)

```swift
// Today (HomeDashboardView.body):
//   if tutorialProgress.isComplete { graduatedDashboard(snapshot:) } else { tutorialHome(snapshot:) }

// This task:
switch HomeFlowStateMap.state(inputs: flow.inputs, cookContext: flow.cookContext) {
case .error:
    errorState(retry: flow.retry)               // FLEmptyState "Dashboard unavailable" + Retry (existing recipe)
case .emptyNew, .partlyStocked, .cooking, .returning:
    operationalDashboard(inputs: flow.inputs, state: state)
}

// operationalDashboard reuses the graduated sections as-is — HomeDecisionHeader,
// HomeDailyNutritionRing (→ onSwitchToProgress), HomeLiveAssistantSection,
// HomePrimaryRecommendationCard (→ onOpenRecommendation), HomeUseSoonAlert
// (→ onSwitchToKitchen), HomeFallbackOptionsRow, HomeMyRhythmSection,
// HomeSecondaryActionsSection — and adds two Home-owned pieces:

// A. Progressive setup strip — remaining steps derived from inputs, shown only while steps remain:
//    healthProfile == nil        → "Complete profile"      (onCompleteProfile)
//    inventoryItems.isEmpty      → "Add what's in your fridge" (onScan)
//    totalMealsCooked == 0       → "Cook your first recipe" (primary action)

// B. Optional restartable learning panel — collapsed entry ("Practice with Le Chef"),
//    expandable anywhere in any state; never a gate. Reuses TutorialProgressView +
//    TutorialQuestCard; quest CTAs route through the existing onQuestCTA(quest:), whose
//    practice flows are already non-mutating (savesToInventory: false, logsMeals: false —
//    art_574HY2JT §2). Completed quests show as chips; restart re-runs the practice.
```

Two invariants the presentation must keep. **Anchors:** the panel marks `"progressView"`
and `"quest_<rawValue>"`; My Rhythm and Live Assistant sections keep
`"myRhythm"`/`"liveAssistantEntry"` — tours present only when their anchors exist,
which is today's semantics, unchanged (art_574HY2JT §3). **Footer:**
`HomeResetFooterSection` keeps its reset and skip-tour buttons with existing semantics —
skipping now only affects the panel's completed-quest chips. Every enabled control
routes through an existing callback with data-backed content; a control with no
destination does not render enabled.

### 4 · Check package — `apps/ios/Tools/home-flow-check` (new)

A clone of the proven historical-nutrition-check pattern: real production sources copied
in by `Scripts/refresh.sh`, compiled against GRDB on Linux, XCTest over migrated
synthetic state (art_R7TpjWAJ §3; baseline 12/12 verified this session).

```swift
// swift-tools-version:6.0
// Linux-safe check package for the operational Home flow. The test target compiles the
// REAL Home flow sources plus the persistence sources they consume. Those sources are
// not committed here; run Scripts/refresh.sh to copy them in before `swift test`.
let package = Package(
    name: "home-flow-check",
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")],
    targets: [
        .target(name: "HomeFlowCheck", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Sources/HomeFlowCheck"),
        .testTarget(name: "HomeFlowCheckTests", dependencies: ["HomeFlowCheck"], path: "Tests/HomeFlowCheckTests"),
    ]
)
```

`Scripts/refresh.sh` copies in, and fails loudly on missing: the new `Feature/Home` flow
files + `HomeDashboardModels.swift`; Domain models (`Inventory`, `Recipe`,
`DashboardModels`, `HealthProfile`, `UserProgress`, `Ingredient`, `IngredientSwap`,
`DishTemplate`, allergen membership); repositories (`UserDataRepository`,
`InventoryRepository`, `RecipeRepository`, `RecipeScoring`); services
(`PersonalizationService`, `SpoilageService`, `NutritionSnapshotService`,
`NutritionService`); `Migrations.swift`; and a `Notification.Name` shim (the real
extension lives in a file that pulls in UserNotifications and cannot compile on Linux —
same reason as the template).

Tests are XCTest, per-test UUID SQLite queues, migrations pinned with
`migrate(upTo:)` to v20, fixed literal timestamps, and `bitPattern`-exact comparisons
wherever macro arithmetic is asserted. Two families: pure map tests (state + primary
action over constructed inputs) and repository-backed tests that seed migrated synthetic
states and read through the real repositories — empty/new, partly stocked, depleted
(returning + restock), mixed progress, skipped learning (quest progress untouched while
the dashboard still resolves its state), and relaunch (queue closed and reopened, inputs
reloaded identically — personal data intact, nothing reset).

## State model

Five operational states, mapped from repository outputs. The map is pure and total:
identical inputs always resolve to the identical state, and every state names the action
Home leads with.

Transitions: `LOAD` (repository outputs) feeds the pure `STATE MAP`. Data states —
empty/new (no stock · no meals), partly stocked (stocked · no meals), returning
(meals ≥ 1) — and `ERROR` (inputs nil; retry reloads) are data-derived. `COOKING` is the
one non-repository signal: a dashed override edge — cook context present overrides any
data state; context ends → re-map to the data state. The cooking override is injected by
the view layer from Live Assistant coordinator state.

| State | Entry condition (all from repository outputs) | Presentation | Primary action | Exit |
|---|---|---|---|---|
| empty/new | inventory empty ∧ totalMealsCooked == 0 (pre-onboarding users sit here briefly under the onboarding cover) | Setup-led dashboard: greeting, progressive setup strip, learning panel entry | Complete profile when `healthProfile` nil, else Scan fridge | Stock lands → partly stocked; first meal → returning |
| partly stocked | inventory non-empty ∧ totalMealsCooked == 0 | Decision dashboard: primary recommendation, use-soon action, fallbacks; setup strip only if profile still missing | Cook the data-backed recommendation when one exists, else Scan fridge | First logged meal → returning |
| cooking | Live Assistant cook context present (view-injected; no persisted source on this branch) | Resume surface above the dashboard: recipe context, live assistant entry | Resume cook | Context ends → re-map to the underlying data state |
| returning | totalMealsCooked ≥ 1 (durable evidence, ranks above stock states) | Full decision dashboard: streak badge, nutrition ring, recommendation, use-soon, fallbacks, my rhythm | Restock when inventory depleted, else Cook the recommendation | Persists; error only on load failure |
| error | load threw with no last-good inputs | `FLEmptyState` "Dashboard unavailable" + Retry; a failed refresh mid-flight keeps the last good sections on screen | Retry | Successful load → the data state |

Learning progress is deliberately absent from this table — it decorates nothing and
gates nothing. Quest completion remains a recorded fact (the storage key stays written)
that only the panel's chips and the unchanged Progress-tab policy read; the dashboard
state map never consults it.

## Verification

Every deliverable carries observable criteria with a named verifier — and the two
checks this workspace cannot execute are recorded as such, never simulated.

| Deliverable | Acceptance criterion | Verified by | Failure looks like |
|---|---|---|---|
| State map correctness | `HomeFlowStateMap` is pure, total, and precedence-ordered: error > cooking > returning > stock states; every input combination resolves; learning progress never appears as an input | Pure XCTest cases in `home-flow-check` | Two states for one input, an unmapped default, or a map that reads `tutorialProgress` |
| Data provenance | Counts, totals, freshness basis, and primary actions derive from real repository outputs on migrated v20 synthetic queues — nothing hard-coded | Repository-backed XCTest over synthetic seeds: empty/new, partly stocked, depleted, mixed progress, skipped learning, relaunch-reopen | An asserted number that survives only because the test seeded the view; freshness computed from anything but expiry dates; unknown expiry rendered as zero urgency |
| Gate replacement | The operational dashboard renders in all four data states regardless of tutorial progress; the learning panel is optional, restartable, and never blocks content; setup strip appears only while steps remain | Linux-compiled read layer + map tests; source-level review of the fork; native sim verification deferred (below) | A stocked user still seeing quest cards, or a panel that forces itself over the dashboard |
| Callback contract | Home's 13-member init surface is byte-identical; every enabled control routes to an existing callback with data-backed content; no blank stubs | The compiler against the untouched `ContentView` call site, plus a source audit of every enabled control | A new button with no destination, or any signature drift that forces a `ContentView` edit |
| Practice isolation | Practice flows never write real Kitchen/history data | Call-site audit that `savesToInventory: false` / `logsMeals: false` demo routes are unchanged; relaunch test proves personal data intact | Any practice path that mutates inventory or journal rows |
| Stale-response cancellation | A superseded load never overwrites a newer one; retry after failure lands the fresh state | Generation-guard test on the view model (Linux-runnable — it is SwiftUI-free) | An older GRDB-observer reload clobbering newer inputs |
| Package + repo checks | `bash Scripts/refresh.sh && swift test --package-path apps/ios/Tools/home-flow-check` green on Linux; `scripts/offline_audit.sh` and `scripts/audit_swift_cohesion.sh` results recorded in the PR | Command output captured and committed; per-milestone logs in the PR description | A red build, a skipped refresh, or an audit result quietly omitted |
| Native evidence — **deferred** | SwiftUI renders at 390×844 and 1440×900, keyboard/focus paths, large-text (Dynamic Type), and VoiceOver/contrast audit | **Unexecuted** — no macOS host exists in this workspace. Recorded in the PR as deferred checks with the exact commands to run them. Fixture screenshots from this environment would be web mockups or source assertions, which the brief forbids presenting as native evidence | (This row documents the honest gap — it is not a pass) |

Two housekeeping checks complete the trace. The PR carries a first-run-to-returning
acceptance trace written from the synthetic-state tests (which states resolve, which
actions fire, what persists across relaunch) and a clear split between what was executed
on Linux and what stays deferred. "Hosted app checks" from the brief: no hosted-app
configuration exists in the repo — the root `package.json` is an unrelated Electron
manifest (art_R7TpjWAJ §5) — so the check record covers the package tests plus the
repo's own audit scripts and says exactly that.

## Locked decisions

Settled inputs for the execution plan; reopening one takes a user decision.

1. **Protected files stay read-only.** `ContentView.swift`, `AppDependencies.swift`,
   `SpotlightTutorialOverlay.swift`, `SpotlightCoordinator.swift`, core
   query/migration/logging files, Kitchen/Inventory code, weekly-plan code, and
   journal-correction code are never edited. Everything new lives in
   `apps/ios/Feature/Home/` (view, models, read model, view model) and
   `apps/ios/Tools/home-flow-check/`.
2. **Compatibility invariants.** Home's 13-member init surface is preserved
   byte-for-byte. The `TutorialProgress`/`TutorialQuest` types and the
   `"tutorialProgressStorage"` key remain, written exactly as today — quest completion,
   skip, and reset keep their current write behavior, so Progress-tab gating in
   `ContentView` is untouched. The four spotlight anchors (`"progressView"`,
   `"quest_<rawValue>"`, `"myRhythm"`, `"liveAssistantEntry"`) keep publishing wherever
   their content renders.
3. **Behavior decisions.** The dashboard gate becomes the state map — learning progress
   is never consulted for dashboard presentation. The learning panel is optional and
   restartable in every state. Practice stays isolated: the existing non-mutating demo
   routes (`savesToInventory: false`, `logsMeals: false`) are preserved, never bypassed.
   The cooking state reads only the Live Assistant coordinator's context surfaced as a
   value — no persisted active-cook record is invented. Freshness is expiry-date based
   only.
4. **Verification split.** Executed here: `home-flow-check` Linux tests (pure map +
   repository-backed on migrated v20 synthetic queues), the repo's `offline_audit.sh`
   and `audit_swift_cohesion.sh`, and generation-guard cancellation tests. Deferred and
   recorded as unexecuted in the PR, with commands to run them: SwiftUI 390×844 /
   1440×900 fixture renders, keyboard/focus paths, Dynamic Type, VoiceOver/contrast
   audit — no macOS host exists in this workspace, and no web mockup may stand in for
   them.
5. **Delivery contract.** Draft PR into `obv/fl-next-historical-nutrition-r1` — never
   merge, never `main`. Up to four passing commit milestones, each pushed only after
   workflow, permission, and attribution checks (Sam Gu author + bot co-author trailer,
   per project policy). The PR records expected conflicts with the older Home proposals
   — planning/ §1 "Home" and the same-base PRs #61/#62 that touch `ContentView.swift` —
   plus working behavior, exact check results, unexecuted native checks, assumptions,
   and a Handoff section with resume commands.
6. **Labeled assumptions.** (1) "Hosted app checks" has no in-repo referent — the root
   `package.json` is an unrelated Electron manifest (art_R7TpjWAJ §5); the check record
   covers package tests plus repo audit scripts and states this plainly. Reversal: the
   operator supplies a hosted-app target. (2) `todayMacros()` returning zero means
   genuinely-none-logged at the API level; the read model passes it through as-is rather
   than re-interpreting. (3) No open questions block the plan — the brief names branch,
   states, gates, callbacks, design language, evidence rules, and PR contract.

## Resuming implementation

1. Recover context: this spec + `art_574HY2JT` + `art_R7TpjWAJ` (full research), and the
   proposed-but-unapproved plan (state map → read model → view fork → check package,
   one draft PR, 2–4 milestone commits).
2. Toolchain: Swift 6.4 Linux at `/home/user/work/swift-toolchain` (proven this session —
   `historical-nutrition-check` baseline 12/12). Re-download if the sandbox is fresh.
3. Verify the push path first: dry-run push + attribution check (Sam Gu author,
   obvious-autobuild bot co-author trailer) before any real push.
4. Follow the milestone sequence in Locked decision 5 and the verification table above.
