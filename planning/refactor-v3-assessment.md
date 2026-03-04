# FridgeLuck Refactor Plan v3 — Full Assessment

## Codebase Reality Check

Before evaluating any plan, the actual numbers matter.

| Metric | Value |
|---|---|
| Non-vendor Swift files | ~75 |
| Total LOC (non-vendor) | ~20,000 |
| SPM targets | 1 executable + 1 test |
| External dependencies | 1 (GRDB) |
| Test files | 1 (239 lines, 3 tests) |
| Test target imports AppModule | No |
| Protocols in the codebase | 2 (`RecipeGenerating`, `IngredientCatalogResolving`) |
| Files referencing `AppDependencies` via `@EnvironmentObject` | 16 |
| Files importing GRDB | 21 (1 in Features, 5 in Services, 2 in Recognition, 8 in Data, 1 in root, 1 in Tests) |
| Feature directories with sub-folders | 0 (all flat) |
| Format | Swift Playgrounds App (`.iOSApplication`) |
| Developer count | 1 |

This is a small, well-functioning, single-developer app. The refactor plan should be proportionate to this reality.

---

## What Plan v3 Gets Right

### 1. Target Count Is Reasonable

Seven targets for ~75 files (growing to ~120 after hotspot decomposition) is proportionate. That's ~17 files per target on average — enough to justify the module boundary overhead without creating targets that hold 2-3 files each.

The deferred `FLCapabilityAgents` and `FLIntegrationGeminiLive` targets are correctly scoped as future work. Scaffolding empty targets now adds no value and creates maintenance burden.

### 2. Abstraction Policy Is Disciplined

The four criteria for adding abstractions and three anti-criteria are well-calibrated:

> Create abstraction only when at least one is true:
> 1. There are multiple implementations now.
> 2. A second implementation is imminent.
> 3. The abstraction isolates a side-effect boundary.
> 4. There are 3+ consumers with duplicated coupling.

This prevents the most common refactoring failure mode: adding protocols with one implementation and no tests using mocks. The two existing protocols (`RecipeGenerating`, `IngredientCatalogResolving`) both exist because they have multiple runtime implementations — that's the right bar.

One clarification needed: criterion 3 ("isolates a side-effect boundary") could be interpreted broadly enough to justify protocols for every repository and service (they all touch the database). The intent should be: add abstraction at side-effect boundaries **only when you need to swap or mock that boundary** — not just because something technically has a side effect.

### 3. Cohesion Over LOC Is the Correct Framing

> LOC is a guide, not a hard stop.
> One primary reason to change per file.
> If a file has 2+ independent state machines, split it.
> If editing one concern regularly risks another concern, split it.

This is better than any LOC number. A 400-line file with one cohesive concern is fine. A 150-line file mixing route composition, business logic, and persistence access is not.

### 4. Hotspot Decompositions Are Concrete and Well-Scoped

Each decomposition follows a consistent pattern and the individual file names map to real cohesion boundaries. The decompositions for the six hotspot files are well-reasoned:

**IngredientReviewView (1,099 LOC) -> 8 files.** The split separates the summary display, confidence-grouped sections, correction interaction flow, and spotlight overlay — these are genuinely independent concerns that change for different reasons.

**HomeDashboardView (947 LOC) -> 7 files.** Tutorial cards, insights, and progress sections are distinct visual/data domains.

**ScanView (770 LOC) -> 7 files.** This file currently has 17 `@State` properties covering camera capture, detection processing, navigation, permissions, and diagnostics. Splitting state into `ScanSessionState` and orchestration into `ScanSessionViewModel` is exactly right. The `ScanCaptureSection`/`ScanAnalyzingSection`/`ScanErrorSection` split follows the view's actual mode transitions.

**OnboardingView (736 LOC) -> 7 files.** Step-based wizard decomposes naturally into per-step views.

**DemoModeView (777 LOC) -> 5 files.** Fewer pieces, appropriate for the simpler structure.

**RecipePreviewDrawer (574 LOC) -> 7 files.** This is the most aggressive split (82 LOC average per file). Some sections (the CTA, the header) may be 40-50 lines. Not harmful, but worth noting that not every file needs to exist on day one — if `RecipeCTASection` is just a button, it can stay inline in the screen until it grows.

### 5. Migration Order Is Correct

Tests before structural moves is right. The sequence — baseline safety, structure alignment, hotspot decomposition, boundary hardening, Gemini scaffold, polish — is logically ordered and each phase has a clear deliverable.

### 6. Feature Folder Template Is Practical

The `Screen/State/ViewModel/Sections/Components/Flow/Ports/Mappers` template gives contributors a predictable place to put things. The naming conventions (`...Screen`, `...Section`, `...Row`, `...Card`, `...State`, `...Action`, `...ViewModel`) eliminate ambiguity.

The "avoid `Helpers`, `Manager`, `Utils`" rule is correct. These are names that mean "I didn't think about where this belongs."

---

## Issues That Need Resolution Before Execution

### Issue 1: Domain Models Import GRDB

This is the most consequential issue in the entire plan. The plan defines `FLDomain` as a separate target for models and ports. But all five domain model files import GRDB:

```
Data/Models/Recipe.swift         -> import GRDB (FetchableRecord, PersistableRecord)
Data/Models/Ingredient.swift     -> import GRDB
Data/Models/HealthProfile.swift  -> import GRDB
Data/Models/DishTemplate.swift   -> import GRDB
Data/Models/UserProgress.swift   -> import GRDB
```

These models conform to `FetchableRecord` and `PersistableRecord` with explicit `CodingKeys` mapping to snake_case database columns. They are inherently persistence-shaped.

If `FLDomain` is supposed to be infrastructure-free, these models can't live there as-is.

**Options:**

| Option | Work | Tradeoff |
|---|---|---|
| A. `FLDomain` depends on GRDB | Minimal | Domain is no longer "pure." Every target importing Domain transitively sees GRDB. Honestly reflects reality: these models ARE persistence types. |
| B. Split each model into domain struct + persistence extension | Moderate (per model) | Clean separation. Domain has plain structs; Platform has GRDB conformance extensions. Creates two files per model and potential mapping boilerplate. |
| C. Keep models in `FLPlatformPersistence` | Minimal | Models live where they're used. Features depend on Platform for model types. Less ideologically clean but matches the codebase's actual design. |

**Recommendation: Option A.** The models are persistence-shaped by design — they have `CodingKeys` matching database column names, and the entire app flows through GRDB. Pretending otherwise by splitting them into "pure" structs and persistence extensions creates boilerplate without practical benefit. There is no second persistence backend, no network DTO layer, and no plan to add one during this refactor. GRDB is lightweight. Having `FLDomain` depend on it is an honest representation of the architecture.

If a second data source appears later (e.g., a Gemini Live API returns recipe data in a different shape), that's the time to introduce domain/DTO separation — not now.

The plan should state this decision explicitly under "Assumptions and Defaults."

### Issue 2: Service Layer Placement Is Ambiguous

The plan defines `FLCapabilityCore` and `FLPlatformPersistence` but does not specify where the 9 current services land. Five of them import GRDB directly and receive `DatabaseQueue` in their constructors:

| Service | Imports GRDB | Current Behavior |
|---|---|---|
| `NutritionService` | Yes | Queries nutrition data from DB |
| `PersonalizationService` | Yes | Reads/writes user preferences in DB |
| `HealthScoringService` | Yes | Queries DB, computes health scores |
| `SubstitutionService` | Yes | Queries DB for substitution candidates |
| `DishEstimateService` | Yes | Queries dish templates from DB |
| `ScanRunStore` | No | In-memory scan session state |
| `RecommendationEngine` | No | Orchestrates repos + scoring + generation |
| `ImageStorageService` | No | File system I/O |
| `DemoScanService` | No | Demo scenario orchestration |

Without an explicit placement decision, Phase 2 ("move files to taxonomy folders") will require ad-hoc judgments under time pressure.

**Recommended placement:**

| Service | Target | Rationale |
|---|---|---|
| `NutritionService` | `FLPlatformPersistence` | Direct DB dependency, behaves like a repository |
| `PersonalizationService` | `FLPlatformPersistence` | Direct DB dependency |
| `HealthScoringService` | `FLPlatformPersistence` | Direct DB dependency |
| `SubstitutionService` | `FLPlatformPersistence` | Direct DB dependency |
| `DishEstimateService` | `FLPlatformPersistence` | Direct DB dependency |
| `ImageStorageService` | `FLPlatformPersistence` | File system I/O (platform concern) |
| `RecommendationEngine` | `FLCapabilityCore` | Orchestration over repos, no direct DB access |
| `ScanRunStore` | `FLCapabilityCore` | In-memory session state for scan pipeline |
| `DemoScanService` | `FLFeatures` | Demo-specific, only used by DemoModeView |

The five GRDB-coupled services are functionally repository-adjacent. They belong in Platform alongside the repositories they resemble.

### Issue 3: `FLApplication` Is Too Thin for a Separate Target

The plan lists `FLApplication` (ports/use-cases) as a separate SPM target. Concretely, what goes in it?

- `AgentConversationProviding` — one protocol, scaffolded, no implementation yet
- No other ports are being added now (per the abstraction policy)
- No use-case layer exists in the current codebase

That is a target with 1-2 files containing protocol declarations. The compilation and dependency graph overhead of a separate SPM target is not justified.

**Recommendation:** Merge `FLApplication` into `FLDomain`. Create a `Domain/Ports/` subfolder for protocol types. `AgentConversationProviding` lives at `Domain/Ports/AgentConversationProviding.swift`. If the ports layer grows substantially later (5+ protocols with real consumers), extract it then.

This reduces the target count to 6:

```
FridgeLuckApp           (executable)
FLDomain                (library)   — Models + Ports
FLDesignSystem          (library)   — Theme, Motion, Components
FLPlatformPersistence   (library)   — Database, Migrations, Repos, DB-coupled Services
FLCapabilityCore        (library)   — Recognition, Intelligence, non-DB Services
FLFeatures              (library)   — All feature folders
```

### Issue 4: Cross-Target `AppDependencies` Wiring Is Undefined

Currently, 16 feature files access `AppDependencies` via `@EnvironmentObject`. After the multi-target split, the question is: where does `AppDependencies` live, and how do features access it?

The plan says *"Feature code should consume scoped dependencies rather than full-container reach where possible"* but doesn't specify the mechanism. This is the hardest part of the multi-target migration.

**The dependency graph constrains the answer:**

```
FridgeLuckApp -> FLFeatures -> FLCapabilityCore -> FLDomain
                            -> FLPlatformPersistence -> FLDomain
                            -> FLDesignSystem
                            -> FLDomain
```

`AppDependencies` references concrete types from `FLPlatformPersistence` (repos, DB-services) and `FLCapabilityCore` (recognition, intelligence). So it needs to live in a target that depends on both.

**Options:**

| Option | Where `AppDependencies` Lives | How Features Access It |
|---|---|---|
| A. Keep in `FLFeatures` | FLFeatures (which depends on Platform + Capability) | `@EnvironmentObject` as today. Minimal change. |
| B. Move to `FridgeLuckApp` | App composition root | Features can't reference the type directly. Would need protocol or scoped structs. |
| C. Scoped dependency structs | Each feature defines its own deps struct | `FridgeLuckApp` constructs scoped structs. Better isolation, more wiring code. |

**Recommendation: Option A for now.** `AppDependencies` stays in `FLFeatures`, which already depends on both `FLPlatformPersistence` and `FLCapabilityCore`. Features continue using `@EnvironmentObject var deps: AppDependencies`. `FridgeLuckApp` creates the instance and injects it.

This is the smallest change that works. Option C is better architecture in theory, but adding ~10 scoped dependency structs + wiring code is work that should be motivated by a real problem (e.g., a feature accidentally using a service it shouldn't), not by principle.

The plan should state this explicitly rather than leaving it as "where possible."

### Issue 5: SPM Target Creation Is Not a Named Phase

The migration phases are:

1. Baseline safety
2. Structure alignment (move files to folders)
3. Hotspot decomposition
4. Boundary hardening (remove direct infra imports)
5. Gemini seam scaffold
6. Polish

Phase 4 requires SPM targets to exist — you cannot enforce "no GRDB import in features" without compile-time module boundaries. But the target creation itself (rewriting Package.swift, adding `public` access modifiers to all shared types, fixing compilation errors) is not listed as a phase.

This is the single most disruptive step in the entire refactor. When you go from 1 target to 6, every type shared across target boundaries needs `public` on the type and its relevant members. Based on the codebase, that's roughly:

- All domain model types (~15-20 structs/enums)
- All service/repository classes (~15 types)
- All design system types (~10 types)
- `AppDependencies` and `NavigationCoordinator`
- The two existing protocols and their associated types

That is 40-50+ types gaining `public` modifiers, plus their initializers, properties, and methods. Internal initializers becoming inaccessible across module boundaries is a common source of non-obvious compilation failures.

**Recommendation: Insert an explicit phase between hotspot decomposition and boundary hardening.**

Revised phase order:

1. Baseline safety (expand tests, fix test target)
2. Structure alignment (folder moves, single target still)
3. Hotspot decomposition (file splits, single target still)
4. **Target extraction** (rewrite Package.swift, add `public`, fix compilation)
5. Boundary hardening (now enforceable via compiler)
6. Gemini seam scaffold
7. Polish and guardrails

Phases 2 and 3 happen within the safety of a single target. The build stays green after every file move and split. Phase 4 is the one big-bang change, and it happens only after the folder structure is stable.

---

## What to Explicitly Exclude

Based on general Swift best practices research, the following are good advice for other projects but wrong for FridgeLuck's scope and constraints.

### Do Not Adopt TCA

The Composable Architecture is designed for apps with deeply shared state across many features, large teams needing enforced patterns, and complex navigation graphs. FridgeLuck has ~10 screens with relatively independent flows, one developer, and vanilla `@Observable` ViewModels that work well.

Adopting TCA would rewrite every feature's state management — State + Action + Reducer + Store for each. That is a ground-up rewrite, not a zero-behavior-change refactor. The ceremony-to-benefit ratio is unfavorable for a solo developer at this codebase size.

If the app grows to 30+ features with shared mutable state across many screens, revisit this. Not now.

### Do Not Switch to SwiftData

The app uses GRDB with a bundled SQLite database (`usda_ingredient_catalog.sqlite`), explicit migrations, snake_case column mapping verified by tests, and direct SQL access where needed. GRDB is a deliberate, well-suited choice.

SwiftData migration would touch every model, every repository, every service, and the bundled data pipeline. Zero user-facing benefit. The general advice to "use SwiftData for new iOS 17+ projects" applies to greenfield work, not to an existing app with a working persistence layer.

### Do Not Build an Offline/Online Sync Layer

`SyncCoordinator`, `SyncStatus` enums, operation logs, and `NWPathMonitor` patterns are for apps that sync user data to a cloud backend. FridgeLuck is offline-only. Gemini Live adds a streaming conversation connection, not a data synchronization problem. Building sync infrastructure now is speculation.

### Do Not Add SwiftLint on Top of SwiftFormat

The project already has `.swift-format` configured (2-space indent, 100-char line length). Adding SwiftLint creates two formatting/linting systems with potentially conflicting rules. If specific lint rules are needed beyond formatting (force-unwrap bans, complexity warnings), add targeted SwiftLint rules after the refactor is complete, not during.

### Do Not Use the `Packages/` Directory Pattern

The project is a Swift Playgrounds app where `Package.swift` is the project file. Moving to a separate `Packages/` workspace with an Xcode project wrapper requires migrating away from the Playgrounds format — a separate infrastructure decision outside this refactor's scope.

The multi-target structure works within the existing `Package.swift`. Library targets are defined alongside the executable target in the same file.

### Do Not Pin Dependencies to `.exact()`

The current `"7.10.0"..<"8.0.0"` range for GRDB is appropriate for a solo developer. `.exact()` prevents receiving patch releases with bug fixes. Exact pinning is a team/CI concern for projects where unexpected dependency updates could break others' work. Here, one person controls the update cycle.

### Do Not Use `@Dependency` Struct Clients (Point-Free Convention) Without TCA

The Point-Free pattern of struct-based dependency clients (`struct AudioPlayerClient { var play: (URL) async throws -> Void }`) is tightly coupled to TCA's `@Dependency` property wrapper and `DependencyValues` system. Outside TCA, you would need to build your own dependency injection infrastructure to make this work, which is overhead without payoff.

Standard Swift protocols work fine for the one new abstraction being added (`AgentConversationProviding`). Use protocols.

---

## Additional Items the Plan Should Address

### Second-Tier Hotspot Files

The plan targets the six largest view files, which is correct for priority. But several other files exceed the 300 LOC soft target and likely have multiple reasons to change:

| File | LOC | Concern |
|---|---|---|
| `SpotlightTutorialOverlay.swift` | 594 | Tutorial overlay system — mixed positioning logic, animation, content |
| `AppComponents.swift` | 522 | Design system grab-bag — likely multiple unrelated components |
| `CookingCelebrationView.swift` | 514 | Celebration screen — animation + data display |
| `CookingGuideView.swift` | 487 | Cooking flow — step navigation + timer + completion |
| `RecipeResultsView.swift` | 482 | Results screen — list + filtering + empty state |
| `RecipeRepository.swift` | 482 | Repository — queries + scoring + sorting |

These should be acknowledged as second-tier targets, evaluated after Phase 3 (hotspot decomposition) using the plan's own cohesion rules. Not all will need splitting — `RecipeRepository` at 482 lines might have one reason to change (recipe data access). Apply the rules, don't split by LOC alone.

### Scattered `@AppStorage` Tutorial State

`MyApp.swift` resets 7 `UserDefaults` keys in debug mode. Multiple feature files (`HomeDashboardView`, `IngredientReviewView`, `DemoModeView`, `RecipePreviewDrawer`, `ContentView`) read/write these same keys via `@AppStorage` with hardcoded string constants. Key names are coordinated by convention, not by a shared type.

This is a latent bug source — a typo in any key string silently breaks tutorial state. During Phase 3 (hotspot decomposition), consolidate all tutorial/spotlight keys into a single `TutorialState` type with static key properties. Feature views reference `TutorialState.hasSeenScanSpotlight` instead of `@AppStorage("hasSeenScanSpotlight")`.

### The GRDB Leak in HomeDashboardViewModel

`HomeDashboardViewModel.swift` is the only file under `Features/` that imports GRDB. It executes raw SQL via `deps.appDatabase.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") }`, bypassing the repository layer.

This is a one-line fix: add a `recipeCount()` method to `RecipeRepository` and call it from the ViewModel. Do this in Phase 2 (structure alignment) before file moves, so the import violation doesn't carry into the new structure.

### Test Target Prerequisites

Phase 1 says "expand tests for current behavior before deep moves." Two prerequisites must be resolved first:

1. **`AppModuleTests` does not depend on `AppModule`.** The test target currently only depends on GRDB. It defines its own local structs to test persistence mapping. It cannot test any application type — no services, no repositories, no ViewModels. Before writing characterization tests, add `AppModule` (or its successor) as a dependency of the test target.

2. **Use `swift-testing` for new tests.** The project targets iOS 18+ and Swift 6. Apple's `swift-testing` framework (`@Test`, `#expect`) is the appropriate choice for new tests. The existing `PersistenceMappingTests` can stay as XCTest until naturally touched.

Concrete characterization tests to write in Phase 1:

| Test | What to Verify |
|---|---|
| Confidence routing | `ConfidenceRouter` thresholds produce correct tier assignments for edge values |
| Learning corrections | `LearningService.recordCorrection` persists, lookups return corrections |
| Recommendation fallback | `RecommendationEngine` returns fallback recipes when AI enhancement is unavailable |
| Hydration idempotency | `BundledDataLoader` can run twice without duplicating data |
| Demo payload invariants | Demo JSON files parse without errors, scenario count matches expected |
| Recipe repository CRUD | `RecipeRepository` read/write round-trips preserve all fields |
| Ingredient catalog resolution | `IngredientCatalogResolver.resolve(_:)` returns correct IDs for known inputs |

This gives 7-10 tests covering the most fragile paths. Write them against the current single-target structure before any file moves.

### Pre-Refactor Dead Code Scan

Run Periphery (`periphery scan`) before Phase 2 to identify unused types, methods, and properties. In a 20K LOC codebase, 5-10% dead code is typical. Delete dead code before restructuring — there is no point in moving unused files into a new folder structure and adding `public` modifiers to types nobody calls.

### `.iOSApplication` Format Compatibility

The Swift Playgrounds app format uses `AppleProductTypes` and `.iOSApplication` in Package.swift. While it should support additional library targets that the executable depends on, this should be verified with a minimal test before committing to the multi-target approach:

1. Add one empty library target to Package.swift
2. Have `AppModule` depend on it
3. Import it from one file
4. Confirm it builds

If this does not work in the Playgrounds format, the project would need to migrate to a standard Xcode project first — a prerequisite that should be discovered early, not during Phase 4.

---

## Revised Target Graph

Incorporating the recommendations above (merge `FLApplication` into `FLDomain`, explicit service placement):

```
Targets (6):

FridgeLuckApp            (executable)
  Contents:  MyApp, ContentView, NavigationCoordinator
  Depends:   FLFeatures

FLDomain                 (library)
  Contents:  Models (Recipe, Ingredient, HealthProfile, Detection,
             DishTemplate, UserProgress, DashboardModels)
             Ports (AgentConversationProviding, RecipeGenerating,
             IngredientCatalogResolving)
             ScanContracts
  Depends:   GRDB

FLDesignSystem           (library)
  Contents:  AppTheme, AppMotion, AppComponents (split), BackgroundSystem,
             ShapeSystem, ConfettiOverlay
  Depends:   (none, or SwiftUI only)

FLPlatformPersistence    (library)
  Contents:  AppDatabase, Migrations, BundledDataLoader,
             RecipeRepository, IngredientRepository, UserDataRepository,
             NutritionService, PersonalizationService, HealthScoringService,
             SubstitutionService, DishEstimateService, ImageStorageService,
             USDAIngredientNutritionStaticData
  Depends:   FLDomain, GRDB

FLCapabilityCore         (library)
  Contents:  VisionService, ConfidenceRouter, IngredientCatalogResolver,
             IngredientLexicon, LearningService, NutritionLabelParser,
             ScanBenchmarkRunner,
             RecipeGenerator (+ Factory), AIIngredientNormalizer,
             RecommendationEngine, ScanRunStore
  Depends:   FLDomain, FLPlatformPersistence

FLFeatures               (library)
  Contents:  All feature folders (Home, Scan, Ingredients, Results,
             Recipe, Profile, Onboarding, Demo, Estimate, Shared),
             AppDependencies, DemoScanService
  Depends:   FLDomain, FLDesignSystem, FLPlatformPersistence, FLCapabilityCore
```

Dependency graph:

```
FridgeLuckApp
  └─ FLFeatures
       ├─ FLCapabilityCore
       │    ├─ FLPlatformPersistence
       │    │    └─ FLDomain (+ GRDB)
       │    └─ FLDomain
       ├─ FLPlatformPersistence
       │    └─ FLDomain
       ├─ FLDesignSystem
       └─ FLDomain
```

Deferred (created when Gemini Live work actually begins):

```
FLCapabilityAgents       (library)  — conversation runtime, tool orchestration
FLIntegrationGeminiLive  (library)  — streaming transport, provider DTOs
```

---

## Revised Migration Phases

### Phase 1: Baseline Safety

**Goal:** Establish a safety net before any structural changes.

Steps:
1. Verify `.iOSApplication` format supports multiple library targets (minimal test).
2. Fix test target: add `AppModule` dependency to `AppModuleTests`.
3. Run Periphery. Delete confirmed dead code.
4. Write 7-10 characterization tests using `swift-testing`.
5. Fix GRDB leak: move raw SQL from `HomeDashboardViewModel` to `RecipeRepository`.
6. Capture manual scenario checklist with expected outcomes.

**Gate:** Build succeeds. All tests pass. Manual critical paths verified.

### Phase 2: Structure Alignment

**Goal:** Move files into taxonomy folders. No logic changes. Single target throughout.

Steps:
1. Create the folder structure matching the target graph (App/, Domain/, DesignSystem/, Platform/, Capability/, Feature/).
2. Move files in batches, building after each batch.
3. Consolidate scattered `@AppStorage` tutorial keys into a `TutorialState` type.
4. Update file references and imports as needed (within single target, this is just folder moves).

**Gate:** Build succeeds. All tests pass. No logic changes.

### Phase 3: Hotspot Decomposition

**Goal:** Split the six hotspot files using the plan's locked templates. Single target throughout.

Steps:
1. Split `IngredientReviewView` (1,099 LOC -> 8 files).
2. Split `HomeDashboardView` (947 LOC -> 7 files).
3. Split `ScanView` (770 LOC -> 7 files).
4. Split `OnboardingView` (736 LOC -> 7 files).
5. Split `DemoModeView` (777 LOC -> 5 files).
6. Split `RecipePreviewDrawer` (574 LOC -> 7 files).
7. Evaluate second-tier hotspots (SpotlightTutorialOverlay, AppComponents, etc.) against cohesion rules. Split only those that violate "one primary reason to change."
8. Build and test after each file split.

**Gate:** Build succeeds. All tests pass. Manual critical paths verified. Each new file passes Zabłocki's three questions (testable in isolation? deletable without breaking others? understandable from the name?).

### Phase 4: Target Extraction

**Goal:** Rewrite Package.swift with 6 targets. Add `public` access control. Fix compilation.

Steps:
1. Write the new Package.swift with all 6 targets and their dependencies.
2. Add `public` to all types, initializers, properties, and methods that cross target boundaries. This is the most mechanical and tedious step — expect 40-50+ types to need modification.
3. Fix all compilation errors. Common issues: internal initializers now inaccessible, types not visible across modules, circular dependencies revealing hidden coupling.
4. Verify all tests still pass (test target dependencies may need updating).

**Gate:** Build succeeds. All tests pass. No import of `GRDB` in `FLFeatures` or `FLDesignSystem`. No import of `FLPlatformPersistence` in `FLDesignSystem`.

### Phase 5: Boundary Hardening

**Goal:** Enforce architectural rules now that compiler can verify them.

Steps:
1. Remove any remaining direct infra imports from feature layer.
2. Verify dependency direction: features never import capabilities/platform except through the declared target dependencies.
3. Ensure no lateral feature-to-feature imports (all features are in one target, so this is about file-level discipline, not compiler enforcement).

**Gate:** Clean build with no boundary violations.

### Phase 6: Gemini Seam Scaffold

**Goal:** Prepare the integration boundary for Gemini Live. No runtime behavior.

Steps:
1. Add `AgentConversationProviding` protocol in `Domain/Ports/`.
2. Add boundary types (session, message, configuration) in `Domain/`.
3. Do not create the `FLCapabilityAgents` or `FLIntegrationGeminiLive` targets yet. Create them when writing actual implementation code.

**Gate:** Build succeeds. Protocol compiles. No runtime changes.

### Phase 7: Polish and Guardrails

Steps:
1. Resolve duplicate `Assets.xcassets` build warning.
2. Add `swiftformat --lint` to `.githooks/` pre-commit hook.
3. Add a simple file-size advisory script (warn on files > 300 LOC, non-blocking).
4. Review each target against Zabłocki's three questions.
5. Run full manual critical path checklist one final time.

---

## Assumptions and Defaults (Updated)

1. Current runtime behavior is the source of truth.
2. Dirty worktree is the intentional baseline.
3. Refactor scope is structure and maintainability only — no feature expansion.
4. Architecture remains vanilla SwiftUI + `@Observable`. No TCA. No SwiftData migration. No sync infrastructure.
5. LOC targets are advisory. Cohesion and "reason to change" are the real gates.
6. Gemini Live is near-term. Only boundary scaffolding is added now. Concrete targets are created when implementation begins.
7. `FLDomain` depends on GRDB. Models are persistence-shaped by design. Domain/DTO separation is deferred until a second data source exists.
8. `AppDependencies` stays in `FLFeatures` as the wiring mechanism. Scoped dependency structs are deferred until the flat container causes a real problem.
9. No new runtime dependencies are introduced during this refactor.
10. New tests use `swift-testing`. Existing tests stay as XCTest until naturally touched.

---

## Phase Gate Validation

Each phase must pass before continuing:

**Automated:**
- `xcodebuild test` on iPhone 17 simulator (iOS 26.2) — all tests green.
- No `import GRDB` in feature files (after Phase 4).
- No duplicate asset warnings (after Phase 7).

**Structural (per module, after Phase 4):**
- Can I write a test for this module's core logic without importing unrelated modules?
- Can I delete a feature folder without breaking any other feature's compilation?
- Can a new developer read the folder/file name and immediately know what changes here?

**Manual critical paths (after Phases 1, 3, and 7):**
1. Onboarding gate and save/edit profile.
2. Scan -> Review -> Results.
3. Demo scenarios (all).
4. Correction learning persistence loop.
5. Recipe cook completion + journal write.
6. Dashboard and profile load.
7. Full reset and tutorial state reset.

**Non-functional:**
- No significant startup or scan-path regression from baseline.
- Existing persisted user data remains readable.
