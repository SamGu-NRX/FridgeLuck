# FridgeLuck engineering evidence and recommendations

## Status and decision ownership

Prepared 2026-10-11 for the overhaul lead. This is the GPT-6.1 Sol engineering recommendation, not an approved architecture or execution authorization. The Opus lead accepts or replaces the options below. Sam alone authorizes merges to main. Proposed branch names, directories, contracts and acceptance thresholds do not exist merely because this document names them.

The inspected app baseline is `/Users/samgu/Programming Projects/fridgeluck` at `2fd0dfea1a86eb9d341e43a339e368ff3088c64d`. The spec worktree has the same baseline. Source references without a PR qualifier refer to that commit, with paths relative to the repository root. PR references identify inspected heads. Existing reviewer verdicts are evidence about their reviewed commit, not current acceptance.

The binding execution limit is Linux, 8 CPUs, about 8 GB RAM, no GPU, Xcode or simulator. Pure Swift, Bun/TypeScript and Python work can be tested there. No Linux result proves SwiftUI rendering, iOS permissions, camera/audio, HealthKit or device behavior. No app code, branches, commits or remote state were changed during this investigation.

Context7 lookups for GRDB, Gemini and Firestore all returned the monthly quota error. Recommendations use checked-in source and manifests, not newly verified SDK documentation. Resolve SDK behavior and Linux support in E01 and E19 before dependent implementation. No library upgrade or new dependency is approved here.

## 1. Current-state map

### Modules and runtime flow

| Area | Actual boundary and evidence | Consequence for the overhaul |
| --- | --- | --- |
| App host | `project.yml:58-74` compiles App, Capability, DesignSystem, Domain, Feature, Integration, Platform and Resources into one application target. `project.yml:15-32` defines a separate FLFeatureLogic framework. | Most folder boundaries are organizational, not compilation boundaries. Moving a folder is not enough to make it portable. |
| SwiftPM | `apps/ios/Package.swift:3-4,13-34` calls the package lightweight tooling, exports only FLFeatureLogic and attaches all Tests to a test target depending on GRDB. | Current main is not a portable build of the actual domain and persistence implementation. Some tests depend on the hosted app. PR #27 is a bridge, not the final architecture. |
| Composition | `apps/ios/App/AppDependencies.swift:46-127` constructs services around one DatabaseQueue. It injects recognition correction learning, recipe ranking, meal logging, local confidence and cloud access. | Preserve a single local write authority. Replace concrete dependencies gradually at the composition root. |
| Recognition | `apps/ios/App/AppDependencies.swift:111-122` connects VisionService to LearningService and IngredientCatalogResolver, then builds ReverseScanService. `apps/ios/Capability/Core/Recognition/ConfidenceRouter.swift:24-45,70-88` buckets source scores and explicitly says they are not calibrated probabilities. | Vision remains an Apple adapter. Recognition decisions and correction replay can be portable. Detection certainty and taste preference must remain separate. |
| Recommendations | `apps/ios/Capability/Core/Services/RecommendationEngine.swift:62-109` retrieves exact and near matches, widening search when needed. `apps/ios/Platform/Persistence/Repository/RecipeRepository.swift:90-145` matches ingredient IDs and filters exclusions. `RecipeRepository.swift:155-203` computes nutrition, health and personalization per candidate, then sorts. | Availability currently means set membership, not proof of sufficient mass. Larger corpora also expose repeated per-candidate queries. Both need bounded tests and a measured query plan. |
| Ranking | `apps/ios/Platform/Persistence/Repository/RecipeScoring.swift:55-88` uses fixed coverage, health, time, goal and personalization weights. | This is a rules-based ranker. It is not a trained preference model. Retain it as an evaluation baseline. |
| Logging | `apps/ios/Platform/Persistence/Services/MealLogService.swift:63-85` writes cooking history and inventory consumption in one transaction. The same file imports UIKit at line 3 and accepts UIImage at lines 36-43. | Keep the transaction, split image storage out of the portable service. HealthKit sync is a subsequent external operation, not part of that transaction. |
| Competing finalization | `apps/ios/Feature/Finalization/MealFinalizationViewModel.swift:54-67` writes history and inventory in separate service calls. Leftovers and repeat preference are explicitly TODO. | A failure after the first call can leave history without consumption. Converge this path on MealLogService rather than build a second logger. |
| Native assistant | `apps/ios/Feature/Assistant/LiveAssistantViewModel.swift:38-49,154-169` has local step navigation; lines 174-227 start/stop camera and transport, with a new UUID on reconnect. Lines 286-303 send recipe context when connected. | LeChef already has a camera-first cook mode, not only chat. Its steps and completion state are ephemeral and not an agent-controlled, durable app workflow. |
| Design system | `apps/ios/DesignSystem/AppTheme.swift:1-5,24-56` binds theme values to SwiftUI and UIKit. `project.yml:65` includes the entire folder in the app. | Extract portable semantic tokens separately from native renderers. This plan makes no color, layout, motion or visual-design recommendation. |

The local path is image/OCR input → ingredient resolution and review → inventory intake or recipe lookup → required/near-match candidates → nutrition/health/rule ranking → cooking/finalization → cooking_history, inventory events and streaks → optional HealthKit sync. Cloud generation and reverse-scan ranking are optional paths through GeminiCloudAgent. `RecommendationEngine.swift:167-205` falls back to the local generator after cloud failure. Do not infer that cloud and local outputs have identical ingredient or nutrition provenance.

### Local schema and migrations

`apps/ios/Platform/Persistence/Database/AppDatabase.swift:16-27` opens the Application Support database with foreign keys enabled and migrates it. Lines 31-43 hydrate bundled content after opening. Lines 59-66 select `fridgeluck.sqlite`. `apps/ios/Platform/Persistence/Database/Migrations.swift:7,482` uses one ordered GRDB migrator.

| Migrations at main | Stored state | Evidence in `Migrations.swift` |
| --- | --- | --- |
| v1 | recipes, ingredients, recipe_ingredients, user_corrections, singleton health_profile, cooking_history, badges, streaks | 11-119 |
| v2-v5 | education fields, dish_templates, ingredient_aliases, ingredient display/sprite metadata | 123-200 |
| v6-v8 | history photo and consumed servings, USDA and recipe hydration markers | 204-229 |
| v9 | shelf-life profiles, inventory_lots, inventory_events, aggregate inventory_items | 233-307 |
| v10 | confidence_signal_events, trust_vector_state | 311-339 |
| v11 | title-based repair of history links and deletion of unreferenced ingredientless recipe placeholders | 343-404 |
| v12-v14 | display name/age, ingredient favorites, pantry assumptions, saved winner flag | 408-444 |
| v15 | local notification rules and scheduled opportunities | 448-480 |

Main has no community account, public recipe, moderation, preference-exposure or learned-ranking tables. The current recipe join key is recipe ID plus ingredient ID at `Migrations.swift:37-47`; it cannot retain two separate lines using the same ingredient in different steps. Recipe IDs are local Int64 values, and `apps/ios/Domain/Models/Recipe.swift:46-50,54-77` supports bundled, user and AI-generated origins, not community revisions or source licenses. Domain models also import GRDB at line 2.

Do not select a new migration number from this main snapshot. #4 changes migrations; #32 advertises v19; #45 has v20 snapshots; #44 adds ownership migrations. The accepted integration head determines the next migration. Never rename an already published migration to solve a branch collision.

### What the three learning mechanisms actually learn

1. **Recognition corrections.** `apps/ios/Capability/Core/Recognition/LearningService.swift:44-72` loads the highest-count ingredient for each lowercased Vision label. Lines 78-124 increment a label/ingredient counter and re-query the winner. Lines 131-148 auto-correct after two corrections and suggest after one. It does not learn cuisines, dislikes, portions or user context. There is no decay or stored correction sequence. Startup orders by count only, while live selection uses count then last-use time, so ties can differ after restart. Database errors are swallowed at lines 72,94,124. Suggestion totals live in UserDefaults at lines 153-178. This is a correction dictionary, not a general learner.
2. **Confidence reliability.** `apps/ios/Platform/Persistence/Services/ConfidenceLearningService.swift:89-167` adjusts raw signals using Beta trust states, a weighted geometric mean, low-signal penalties and fixed mode thresholds. Lines 170-225 blend the outcome reward with closeness to the prediction before updating alpha/beta with decay 0.997. It learns trust by signal key, not taste. The stored reward is the blended proxy, not an independent correctness label. `calibrationSnapshots` at lines 234-265 reports error against that proxy. It cannot establish calibration to actual gram or nutrition error.
3. **Recipe personalization.** `apps/ios/Platform/Persistence/Services/PersonalizationService.swift:14-55` adds an average-rating boost, shared-tag cooking frequency over 30 days and a three-day recency penalty. Lines 62-106 record cooking and streaks; lines 110-123 update the latest rating. The code comment says cuisine affinity, but the SQL matches any overlapping tag, including non-cuisine tags. `apps/ios/App/AppPreferencesStore.swift:62-128` persists appearance, units, serving default and haptics only. It is a settings store, not a learned taste profile.

At main, the production caller found for local confidence `recordOutcome` is `apps/ios/Feature/Estimate/ReverseScanMealView.swift:967-984`. Manual recipe selection gives 0.45; accepting the top candidate gives 0.96; another candidate gives 0.78; the fallback gives 0.72. These constants are behavior proxies, not measured recognition accuracy. Ingredient correction calls are real at `apps/ios/Feature/Ingredients/IngredientReviewView.swift:666-677`. Recipe-generation assessment exists at `RecommendationEngine.swift:138-156`, but that path does not collect equivalent outcome evidence.

Planning is more ambitious than implementation. `planning/stage_4-gemini_live/confidence-engine-spec.md:17-24,59-63,114-127` separates task uncertainties and proposes fitted calibrators. `confidence-learning-without-large-datasets.md:30-68` deliberately reduces that to lightweight trust updates for hackathon scope. Do not describe the deployed code as already delivering the fitted models in the former spec.

### Recipes, USDA and corpus defects

Read-only counts from `apps/ios/Resources/data.json` are 166 recipes and 50 ingredient rows. Of those recipes, 141 instructions start with a `Source:` URL and 25 do not. The bundled USDA SQLite has 800 ingredients and 3,998 aliases, counted with a read-only SQLite URI. These counts are observations, not license evidence.

`apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift:7-11,45-82` decodes positional JSON arrays. Lines 113-179 load the first seed. Lines 230-303 refresh existing installs by adding titles not already present, rather than updating existing recipe content. `BundledDataLoaderUSDACatalog.swift:76-106` imports USDA rows by name using INSERT OR IGNORE; existing macros are not replaced. Lines 127-131 use file size and modification time as the hydration marker. That marker is not a content version. `BundledDataLoaderRecipeHydration.swift:82-120` repairs required demo recipes by same-title lookup without an ownership predicate. This is a reason to evaluate #44, not permission to overwrite a same-title user recipe.

The USDA pipeline is JSON-canonical. `scripts/data/README.md:9-14,82-86` identifies the canonical catalog, generated SQLite and freeze policy. `scripts/data/usda_core/build_sqlite.py:42,106-147,153-178` preserves FDC IDs and source metadata in the catalog export. The app-side importer shown above remaps by name and does not retain an explicit FDC foreign key in the app ingredient table. A future resolver must distinguish FDC identity from local IDs and avoid assigning nutrition from raw to cooked forms without evidence.

The scraper targets BBC Good Food collections in `scripts/recipe_scraper/README.md:3-11`. At main:

- `scrape_recipes.py:640-648` resolves against the 50-row seed dictionary, not the complete USDA catalog.
- Lines 742-748 equate milliliters to grams and use 50 g for unknown amounts. Lines 768-775 use substring-based unit guesses and clamp them.
- Lines 789-797 infer vegetarian/vegan status using incomplete text token lists.
- Lines 906-923 silently omit unmapped ingredients and accept a recipe with only two mapped required items. An apparently complete recipe can therefore omit required ingredients from nutrition and feasibility checks.
- Lines 913-915 discard subsequent lines with a repeated resolved ingredient ID rather than aggregate their amounts.
- Lines 821-828 embed attribution in instructions; lines 938-940 derive time from step count. Neither is a structured provenance or time measurement.

PR #43 at `93326d08841e` improves normalization and adds regression tests. It does not finish the proposed corpus pipeline. Its `_estimate_grams` at `scripts/recipe_scraper/scrape_recipes.py:863-890` still treats ml as grams, falls back to 50 g and uses generic volume conversions; lines 1104-1113 still omit unresolved and repeated ingredient lines. Fold useful parser fixes, then supersede these conversion semantics with explicit evidence and unknown states. A successful iOS CI run on #43 does not run Python tests.

No inspected scraper file establishes redistribution rights for the BBC content. A URL attribution is not permission. License review of existing recipes is a release gate, including the 25 recipes without URL headers. Do not scrape more recipes until an approved source manifest states the permitted use of text and images.

### Backend and LeChef authority

The backend is TypeScript, managed with Bun, but the production start script runs Node: `backend/gemini-agent/package.json:6-15`. It uses Express 4, ws, Google Gen AI and Firestore at lines 17-22. Existing dependencies favor reusing this stack, but do not prove any deployed service or credentials work.

`backend/gemini-agent/src/server.ts:23-30` creates one process-wide confidence service, inventory ledger and session store. Routes at lines 41-145 provide generated recipes, reverse-scan ranking, confidence assessment/outcomes/snapshots, inventory and notification plans. WebSockets attach at lines 147-168. Recipe output is prompted JSON decoded and cast at `src/services/recipeService.ts:50-86`; it does not return a resolved ingredient bill of materials. Generation is not an authoritative nutrition calculation.

`src/services/liveSessionGateway.ts:58-92` accepts a client-selected session ID. Lines 108-150 connect Gemini Live and dispatch model tools. Lines 297-313 accept client tool responses and client confidence context. `src/agent/toolRegistry.ts:95-129` lets the inventory tool mutate directly; lines 164-169 register recipe context, live scene assessment, food-safety grounding, inventory mutation and restock planning. `src/inventory/inventoryLedger.ts:13-19,22-53,69-82` stores inventory and idempotency in process memory keyed by ingredient name, without account ownership. `src/services/confidenceService.ts:58-60,122-145` also learns in process-wide memory. Restarts lose those states; multiple users can share them at this main head.

The session store supports memory and Firestore at `src/session/liveSessionStore.ts:92-113`. Firestore writes camera frame base64 at lines 242-255 and retains user text at lines 280-291. No application TTL is present in this inspected version. `src/api/webhooks.ts:13-21,44-67` lacks authentication middleware in this version; task kinds `enrich_inventory` and `send_spoilage_notification` merely break and return success. Those handlers are stubs, not completed automation.

These are source-confirmed boundaries at main, not new claims about a live deployment. PR #39 at `20dc133f4e6b` replaces several of them. Its `src/services/liveSessionGateway.ts:46-52,633-640` rejects client tool responses and client confidence. Its `src/authority/mutationAuthority.ts:10-27` introduces model proposals and client confirmation, but explicitly has no account system. Session authorization is not community authentication. The backend ledger is also not the phone's GRDB inventory; neither main nor the inspected hardening mechanism proves synchronized durable app-state writes.

### CI and evidence limits

Only `.github/workflows/ios-ci.yml` is present on main. Lines 14-24 select `macos-26`, a 20-minute limit and Xcode 26.6. Lines 32-47 install XcodeGen, generate the project, choose a simulator and run hosted tests. Lines 49-99 run advisory Periphery. This does not establish native behavior from a source-only Linux agent, nor does it run backend or data suites.

#16 adds backend/data CI. #27 adds a Linux subset including production sources and compatibility shims; its current `apps/ios/Package.swift` is 256 changed lines relative to its base. Evaluate and use it as a transition aid, then replace source-copy/shim dependence with real package imports. Prefer one copy of production logic over a second test-only implementation.

Queried current GitHub checks were successful for #39, #43, #45, #83, #84 and #85, and failed for #44 and #71. This is status evidence only. No logs were examined to diagnose #44 or #71, and no tests were executed locally during this planning assignment.

## 2. Open-PR topology and recommended trunk strategy

### The graph that matters

`gh pr list -R SamGu-NRX/FridgeLuck --state open --limit 100 --json number,title,headRefName,baseRefName,headRefOid` returned 80 PRs. Edges below mean advertised base → child, not verified containment of every current parent commit.

- main → #4 product loop → #5 meal confirmation → #7 routing evaluation.
- #4 → #8 recognition → #12 cancellation → #13 scan reporting → #38 correction tests → #53 drift study.
- #13 → #47 ingredient-recognition benchmark → #48 preparation, #58 nonfood, #63 multiplate. #13 → #84 help/recovery.
- #4 → #9 real onboarding scan → #23 storage inference, #37 accessibility, #42 groceries → #51 barcode.
- #4 → #11 motion/count fixes → #35 entry naming.
- #4 → #32 allergen groups → #44 bundle refresh → #71 cookbook.
- #32 → #45 historical nutrition → #59 storage benchmark, #61 backup, #62 search, #70 progress, #85 Home spec.
- #5 → #56 corrections → #83 cooking checkpoints. #5 → #14 icon and #66 identifiability study.
- #7 → #31 invariants, #33 confidence extraction, #41 portion study → #64 intervals and #82 acquisition faultlab; #7 → #46 comparison and #57 ambiguity.
- #4 also has direct children #15, #27, #28, #34, #36, #49, #55, #60, #75, #76, #77 and #79. #32 also has #52, #54 and #68.
- main has independent advertised bases for #3, #6, #16-22, #24-26, #29-30, #39-40, #43, #65, #67, #74, #78, #80 and #81. #29 → #69. #40 → #50.

Two actual containment checks change the merge recommendation. `git merge-base --is-ancestor` returned success for #19, #21, #22, #25, #26 and #30 heads inside #39 `20dc133f4e6b`. It returned false for #24 inside #39. #45 `c9555fc649ad` is not an ancestor of #44 `7dc2b219204c`, even though #44 includes overlapping NutritionSnapshotService and migration changes. Do not treat #44 as a safe substitute for #45 without reconciling that delta.

### Recommended integration procedure, subject to lead approval

1. Sam or an explicitly authorized integration owner creates `integration/overhaul-20261011` from main `2fd0dfe`. No agent merges to main. This investigation did not create the branch.
2. Freeze a full-SHA inventory and writer handoffs. Current-head review is required before accepting a repair. Preserve original branches and PRs; do not rebase active writers out from under their tasks.
3. Build the safety base from #6, #16 and #18, then #39 as the backend aggregate and #24 as its separate recipe-validation delta. Reconcile #24's HTTP behavior with #39's validators. Include #20 only after updating its source citations to the resulting tree.
4. Build the product base from #4; add #8 → #12 → #13 and #9 → #23, plus #11, #15, #28, #34, #36, #37 and #32. Add #5 and #33 where confidence routing is retained. Carry #7 and #31 as evaluation/invariant infrastructure rather than force unrelated studies into the product release.
5. Add #40's audited reference corrections and #43's parser regressions. Regenerate and compare the USDA SQLite under the accepted catalog owner. Do not overwrite the seed merely to increase recipe count.
6. Reconcile #45 and #44 in that order. The historical-nutrition writer owns snapshot arithmetic; the refresh writer owns adoption/refresh. Integrate only one snapshot implementation. #44 has an advanced head and failing current native CI; establish the failure from logs before continuing. Do not repeat the old compile fix on assumption.
7. Add #56 only when the existing inventory owner provides the attributable, idempotent compensator. Then consider #83 checkpoint persistence and #71's cookbook store, with the current #71 failure diagnosed. Native journey acceptance remains separate.
8. Cut a tested `w0` integration point. Publish exact source/test/build identities and migration order. All new tasks below start after this point. Optional studies and UI expansions cannot hold the safety base indefinitely.
9. At each wave, fold only dependency-ready changes into the integration branch through Sam's authorized process. Run collective Linux checks and macOS CI on that tree, not merely each historical PR. Sam decides the final merge to main. Never enable auto-merge.

This favors the existing chains over reconstructing their fixes independently. The alternative is a clean implementation from main with selected patches; that reduces inherited breadth but discards proven corrections and requires reconstructing migration behavior. A second alternative is merging all 80 PRs into a catch-all branch. I do not recommend it: studies, incomplete native features and duplicate backend changes would all become release blockers.

### Proposed disposition of every open PR

These are integration recommendations, not acceptance verdicts or instructions to close PRs. A grouped row covers each listed PR explicitly.

| PRs | Recommendation and reason |
| --- | --- |
| #3 | Defer portfolio prose. It does not unblock the overhaul. |
| #4, #5 | Fold after exact-head review. They establish the corrected product loop and confirmation semantics on which most descendants rely. |
| #6 | Fold. Native notification concurrency fix is a bounded foundation change. |
| #7 | Retain offline routing evaluation; fold infrastructure when #33/#31 need it. Do not mistake synthetic policy results for photo accuracy. |
| #8, #9, #12, #13, #15, #23, #28, #32, #34, #36, #37 | Fold corrected behavior and tests after current-head review. These address real scan, lifecycle, logging, allergy, privacy or parsing boundaries. Preserve accessibility fixes through later UI replacement. |
| #11 | Fold reduced-motion/count behavior. Later visual changes must preserve it. |
| #14, #35 | Supersede visual entry choices under the lead's redesign. Retain any useful accessibility or route-identity checks; do not spend a release gate on icon preference. |
| #16, #18 | Fold CI changes after checking resulting workflows together. |
| #17 | Drop from merge candidates. It is explicitly an integration preview marked do not merge. Use only as conflict evidence. |
| #19, #21, #22, #25, #26, #30 | Fold through #39, which contains these exact heads by ancestry. Do not replay their commits again. |
| #20 | Fold privacy documentation only after updating it to the integrated authorities and retention behavior. |
| #24 | Fold separately. It is not contained in #39 and guards generated recipes. Check validator and 422 compatibility. |
| #27 | Fold as a portability bridge, then supersede copied-source/shim setup with real SwiftPM boundaries. |
| #29 | Fold scheduling correction after tests. Do not infer remote delivery from planner output. |
| #31, #33, #38 | Retain/fold actual production invariant and confidence tests. They are useful regression foundations, not preference-learning completion. |
| #39 | Fold aggregate backend safety work after current-head review. Current native CI is green, but that alone does not test backend authority. |
| #40 | Fold audited reference corrections after Python tests and regenerated SQLite comparison. |
| #41, #46-50 | Retain as offline research/evaluation, not product dependencies by default. #50 requires held-out food groups and honest yield limits. #46-49 have unreviewed forward deltas in the closeout. |
| #42 | Fold reviewed-amount grocery intake only after its current adapter checks and native gate. It supports pantry quality. |
| #43 | Fold parser fixes and regression tests; supersede heuristic quantity/partial-ingredient import for the new corpus. |
| #44 | Hold for current-head failure diagnosis and #45 reconciliation, then fold ownership/refresh. Do not label its old broken verdict current without inspecting the forward delta. |
| #45 | Fold snapshots before mutable bundle refresh after actual replay tests. Preserve upgrade-backfill provenance as distinct from original measurements. |
| #51 | Defer barcode expansion unless the lead includes it in intake scope. Preserve the source-pinned cache work. |
| #52 | Defer weekly planning UI. Reuse planner evidence if later approved; it is not a prerequisite to taste learning. |
| #53 | Retain existing bounded drift study. Reviewer acceptance remains exact-head; this is correction learning, not taste evaluation. |
| #54, #55 | Retain pantry and numeric-label eval as test inputs after checking provenance/current heads. Do not hold the base for a new study. |
| #56 | Hold until production inventory compensation and retry/delete invariants are proven by its existing owner, then fold. |
| #57-60 | Retain exact-head accepted offline studies/benchmarks with their stated limits. Fold #59's benchmark when performance evidence is needed. |
| #61 | Hold native restore integration until verified; reuse archive validation only if needed. Restore is a data-integrity boundary, not routine UI cleanup. |
| #62 | Fold the accepted search core if compatible with the new corpus. Rebind index rebuilds to recipe revisions; its older branch acceptance is not collective acceptance. |
| #63 | Retain multiplate benchmark as research. No GPU-dependent classifier work in the Linux implementation plan. |
| #64 | Hold coverage claims until the reviewer correction distinguishes prediction-eligible from full-population coverage. Preserve frozen scorer/data. |
| #65 | Retain source-lineage audit after its incomplete census is resolved. It can inform rights review but cannot grant licenses. |
| #66 | Retain finite-world study after a non-writing artifact verifier. Do not call it photo accuracy. |
| #67 | Retain the accepted backend confidence-contract harness. Run against the integrated backend to detect shared keys and restart loss. |
| #68 | Hold certificates claimed to represent production until exact upstream state replay is provided. Synthetic fixtures remain useful if labelled synthetic. |
| #69 | Retain reminder-boundary study after current-head report checks. Its head advanced beyond the closeout's reviewed commit. |
| #70 | Supersede its UI with the approved redesign; retain provenance/range state and native journey requirements. Current head advanced. |
| #71 | Fold the cookbook store only after #44 and current failing CI are resolved. Existing writer retains ownership; native CRUD is incomplete evidence. |
| #74 | Defer experiment-capsule tooling. Old path-confinement findings are serious but the head advanced; inspect the delta before repeating them. Not needed for this release's basic tests. |
| #75, #76, #77 | Do not fold as-is. Closeout reports specific numerical, accessibility and export defects at matching inspected head prefixes. Continue existing writers only if these features remain in scope; otherwise supersede their UI and preserve needed quantity tests. This plan did not independently reproduce those defects. |
| #78, #81 | Defer standalone SQLite doctor/state-diff tools. Both advanced heads require review; not prerequisites to app migrations tested on closed fixtures. |
| #79 | Supersede the reminder-center plan with the approved host design; retain save/schedule/readback semantics. Only a plan was published at the reviewed head. |
| #80 | Retain failed-load/save-retry requirements for host wiring, but supersede the isolated UI implementation if redundant. Advanced head is unreviewed here. |
| #82 | Defer faultlab acquisition study. It does not unblock CPU-only application logic. |
| #83 | Reuse checkpoint core after #56 and production-adapter tests. Current diff contains a tool package, not native resume integration. |
| #84 | Retain diagnostics/redaction core and recovery requirements; native presentation follows the lead's redesign. Current diff includes native wiring but no runtime proof was collected here. |
| #85 | Use the 400-line operational Home spec as an input to the lead. It is documentation only, not an implemented read model or approved visual plan. |

The external closeout is `/Users/samgu/.long-run/obvious-fleet/closeout/reviewer-fl-form3d-mobility.md`. Lines 18-22 identify old broken #44 and current matching #75-77 heads. Lines 23-45 distinguish partial implementations and advanced heads. Lines 46-53 identify bounded accepted studies. Lines 55-93 explicitly leave many foundational PRs unreviewed. Current #44, #69, #70, #71, #74, #78, #80 and #81 heads differ from the cited reviewed/forward heads. No disposition above converts those historical findings into a newly reproduced defect.

## 3. Architecture options for the six goals

### Goal 1. Community

There is a scope conflict in the historical planning, not evidence of a hidden completed feature. `planning/stage_0-brainstorm/fridgeluck planning.md:281-284` proposes recipe battles, shared creations and university challenges. `planning/stage_2-features_to_build/features.md:262` mentions future mock screens. `product-structure-and-feature-redesign.md:883-892` explicitly deprioritizes forums and social feeds. Sam's new goal reopens that scope. The lead must choose the initial community behavior.

**Option A, recommended if sharing is approved.** Extend `backend/gemini-agent` with an isolated community API, reusing Express and the existing Firestore dependency. Start with published recipe revisions, ingredient-constrained challenges and submissions, saves, reporting and blocking. No direct messages, contact discovery or free-form social feed in the first slice. This limits moderation and privacy exposure while answering the old recipe-sharing intent. It is a recommendation, not an approved product cut.

**Option B.** Add `backend/community-api` using a relational store and separate deployment. SQL is a better fit for memberships, voting uniqueness and moderation queries. It adds a database dependency, deployment, migration and operational owner. Prefer this if the lead commits to broader social interactions or complex queries, not just to isolate folders.

**Option C.** Use a managed auth/data platform with client synchronization. That can reduce server work, but introduces provider decisions and rules-based permissions that differ from the existing server. It still needs abuse handling, deletion, licensed content and tests. Do not choose it solely because it has an iOS SDK.

For A, propose server-issued account identity tied to verified Sign in with Apple, short-lived access sessions and revocable refresh sessions. `project.yml:106-107` declares the entitlement; it does not prove sign-in implementation. Server verification must check issuer, audience, expiry, signature and nonce; the accepted account ID is never a caller-supplied owner ID. Anonymous users keep local cooking and browse only what policy permits. Publishing and voting require an account. Moderator permissions come from server-owned roles.

Proposed collections are accounts, recipe publications with immutable revisions, challenges, submissions, saves, blocks, reports and moderation decisions. Use server ownership checks for every access, stable pagination, revision preconditions, uniqueness/idempotency constraints and tombstones. Firestore transaction behavior, server IAM and emulator support remain documentation/experiment gates. Do not assume client security rules authorize server SDK writes.

Images require a separate object-store decision. Recommend no uploaded media in the initial minimal API until the lead approves storage, stripping metadata, upload bounds, review and retention. Keep the schema able to reference an approved media asset later; do not ship an unmoderated upload endpoint.

Privacy defaults are local pantry, health profile, meal history and taste events. Publishing sends only the recipe revision and chosen public metadata. Never export inventory or health state as implicit community personalization. Require an explicit publication preview, license declaration, report/block support and account/content deletion. A launch with no named moderation operator stays private or disabled. The lead must approve retention periods and treatment of deleted authors' licensed recipes before implementation.

### Goal 2. Real preference and continual learning

**Option A, recommended.** CPU-only local event learning and content-based ranking. Log exposures and deliberate outcomes, build features from recipe metadata and interaction history, fit a small regularized model, then rank only candidates that already pass hard safety and availability checks. This can learn with sparse data, operate offline and remain reproducible in Swift on Linux. It does not promise collaborative filtering or photo correctness.

**Option B.** Server-side collaborative or embedding-based recommendations with opt-in event upload. This may improve discovery once there are enough real users and licensed recipes. It adds sensitive behavioral data, cold-start and deletion obligations. Current population and consent are unknown, so it is premature as the default.

**Option C.** Expand the current hand-built rating/tag/recency score. Cheap and understandable, but still does not test a learned preference function. Keep it as a baseline or fallback rather than present it as the overhaul's learning result.

Proposed event path is `PreferenceEvent` → `RecipeFeatureVector` plus `UserPreferenceState` → `PreferenceModelSnapshot` → `RankedRecipe` with reason codes. Each event has a stable ID, kind, timestamp, recipe revision, exposure ID where applicable, and explicit source. Record shown candidates, selected recipe, cook completion, rating, save, deliberate dislike and substitution preference. A dismissal or silence is not automatically a negative taste label. Corrections/retractions refer to the prior event rather than silently creating another reward.

Separate explicit restrictions, inferred taste and confidence reliability. Explicit allergies and dietary exclusions are hard filters. Taste cannot weaken them. Confidence feedback has observation/ground-truth fields and model/source versions; accepting a suggestion cannot prove gram accuracy. Keep correction histories for deterministic replay, but do not migrate existing aggregate counts into invented individual events.

Recommend a regularized linear or logistic content model with deterministic feature ordering, bounded updates and a fallback snapshot. The lead should approve the objective before E07. Sparse users shrink toward the rule baseline; ratings and explicit dislikes get distinct semantics. Store model version, feature version, training cutoff and source event range. A reset removes local learned state and does not reset explicit safety constraints unless the user separately requests that.

Evaluation must precede enabling the ranker. Compare the current rule baseline, explicit-profile-only baseline, proposed learner and simple popularity/recency controls. Use seeded simulated households with stable preferences, changing preferences, sparse feedback and biased exposure. Separately use consenting real replay logs if available, split by time and user, fit only before the cutoff, and group recipe duplicates across splits. Report NDCG or pairwise ranking performance only where relevance labels exist, preference adaptation, repeat diversity, cold-start fallback and restriction violations. Logged rankings are exposure-biased; do not claim causal improvement from naive replay. Exploration, propensity logging and randomized online trials are a later lead decision, not required for the first offline model.

Recommended release gate is zero hard-filter violations, deterministic restart/replay, and an improvement over the rule baseline on a frozen simulated suite with per-scenario counts. The lead chooses the quantitative improvement and regression budget before evaluation. A simulated improvement proves implementation behavior, not satisfaction among real users.

### Goal 3. LeChef as an agent over app state

**Option A, recommended.** Keep Gemini Live for conversation/perception, but make the phone's portable application core authoritative for local pantry, cooking sessions and logging. The backend reads bounded snapshots and emits typed action proposals. The phone checks permissions, current revision and explicit user approval, executes locally, then sends a structured receipt. This avoids pretending the transient server ledger is GRDB. It preserves useful #39 proposal controls while changing the authoritative store.

**Option B.** Make the backend authoritative for synchronized household pantry and cooking state. Better for multiple devices and shared households, but requires account-bound durable inventory, conflict semantics and a full synchronization contract. That is larger than community publication and should not happen accidentally through a tool handler.

**Option C.** Expand the current session-context tools and prompt only. Low cost, but cannot guarantee inventory, timer or meal-log correctness. Not recommended for mutating actions.

Proposed portable types are `AssistantContextSnapshot`, `ToolInvocation`, `ActionProposal`, `ActionApproval`, `ActionReceipt` and `CookingSessionCheckpoint`. Snapshot revision and proposal payload hash bind approval to what was shown. Tool output identifies evidence, unknown quantities and permitted claims. User instructions, recipe text and community content are untrusted data, not permission instructions.

Start with read-only tools for candidate recipes, pantry summary, recipe/step context and substitution alternatives. Controlled local actions can advance/complete a step, prepare a timer, propose an inventory correction and propose a meal log. A deliberately confirmed timer may be low risk, but microphone transcript alone must not authorize nutrition logging or community publication. Mutation receipts distinguish pending approval, executed, rejected, expired, stale revision and duplicate execution. The LLM cannot manufacture approval. Idempotency survives process restart in the authoritative local store.

Keep cooking useful without Gemini: durable selected recipe revision, completed steps, timers and a deliberate resume prompt. #83's current diff provides a checkpoint tool package; integrate its actual persistence rather than write a competing checkpoint system. LeChef can help decide dinner, prepare ingredients and recover a cooking interruption, with each workflow expressed as deterministic state transitions outside SwiftUI. Online food-safety answers remain advisory and sourced, never a certification that camera-observed food is safe.

Live SDK calls, audio quality, interruption latency and real camera grounding remain unverified without provider access and native runtime. Offline tests should fake the model protocol and exercise reordered, duplicated, cancelled and stale tool messages. They must assert which actual app command executed, not merely that text said it executed.

### Goal 4. More and better recipes

**Option A, recommended.** A versioned, licensed corpus built offline by Python, validated against USDA and shipped as a curated bundle. Retain the existing USDA canonical pipeline and #43 parser fixes. Add explicit source rights, recipe revisions, ingredient-line evidence and quality reports. This fits CPU-only execution and the offline app.

**Option B.** Fetch recipes from a licensed commercial API at runtime. It can increase coverage faster but adds contract costs, quota, availability and caching/redistribution restrictions. Prefer only after a provider agreement, not as an unspecified network fallback.

**Option C.** Generate most recipes with Gemini. Useful for a reviewed draft, not a substitute for licensed provenance, ingredient completeness or cooking quality. Generated steps still require validation and human cooking samples. Do not derive authoritative calories from the model's estimate.

Proposed pipeline stages are rights-approved acquisition → raw snapshot → structured recipe → ingredient resolution → quantity evidence → nutrition calculation → duplicate grouping → quality review → release bundle. Each stage retains its input version and rejection reason. Use permitted sources only: original commissioned recipes, explicit redistribution licenses, or contracted providers. License names are not enough; verify the relevant text, attribution, derivative-use and image terms. Unknown rights quarantine the record.

`RecipeRevision` has source identity, license evidence, attribution, language, structured steps, serving basis and ordered ingredient lines. `IngredientReference` stores FDC identity/preparation, local mapping and resolver version. `QuantityEvidence` distinguishes weighed grams, source-provided grams, approved household measure conversion and unknown. Density, packing, edible portion, raw/cooked form and cooking yield are not interchangeable. Do not make up 50 g to satisfy a numeric field. Preserve unresolved lines; they block complete feasibility and complete nutrition claims.

Compute nutrients from known per-100 g values and quantity evidence. Retain sodium in grams internally, with milligrams only at the display boundary. Unknown mass/nutrients remain unknown; partial nutrition reports its coverage. Cooking yield/retention should be included only when supported evidence exists. #50's study can inform conversion, but its old evaluation protocol does not justify a universal density table.

Duplicate grouping uses source ID/URL plus normalized content and ingredient/step similarity. Keep variant relationships instead of merging distinct dishes by title. Quality is initially a checklist with reasons: legal permission, complete ingredients, usable steps, plausible serving basis, resolution coverage, nutrition coverage and checked diet/allergen claims. A weighted score is an unvalidated heuristic until human judgments establish its usefulness. Neither repeated instructions nor tiny ingredient overlap is a complete recipe.

Deliver a content-versioned manifest, integrity hashes and stable source keys. Ship a startup subset and avoid network dependence for cooking. Optional downloadable packs are a later choice; they need authenticated manifests and atomic install. First prove install/update/remove with #44 ownership and #45 historical snapshots. Catalog changes must not rewrite past nutrition or steal edited user recipes. The lead sets the corpus-size and cuisine-coverage target after rights and quality yield are known. Increasing beyond 166 is measurable; the proposed thousands-level ambition has no sourcing evidence yet.

### Goal 5. Execution and system quality

**Option A, recommended.** One portable SwiftPM package with several dependency-enforced targets, a GRDB persistence adapter proven on Linux, and a thin native host. This provides real compilation boundaries without maintaining a separate package and lockfile for every feature.

**Option B.** Independent SwiftPM packages for every domain capability. Better independent release boundaries if there are multiple clients, but more manifests and dependency coordination than this single app needs today.

**Option C.** Retain the Xcode-only folder layout and expand PR #27's Linux source selection. Useful during extraction, but it keeps portability coupled to curated excludes, shims and potentially copied inputs. Do not use a green subset as proof that all production logic compiles.

For A, propose `packages/FridgeLuckCore/Package.swift` with these targets and same-named `Sources/` and `Tests/` directories:

| Target | Responsibility and allowed dependencies |
| --- | --- |
| FLDomain | Stable value types, IDs, recipe revisions, nutrition/quantity evidence, restrictions, events and command/result contracts. Foundation only. No GRDB records or UI imports. |
| FLRecipeCore | Ingredient/recipe validation, mass/nutrient arithmetic, feasibility, hard filters and ranking orchestration. Depends on FLDomain. |
| FLInventoryCore | Lot allocation, intake/consumption/correction planning and attributable compensation. Depends on FLDomain. |
| FLPreferenceCore | Event reduction, features, bounded model fitting and explanation inputs. Depends on FLDomain. |
| FLAssistantCore | Tool policy, proposal/approval state, stale-revision checks and receipts. Depends on FLDomain and explicit recipe/inventory command contracts. |
| FLCommunityCore | Publication/license DTOs, visibility policy and local synchronization state. Depends on FLDomain. It never owns server authentication decisions. |
| FLFlowCore | Cooking, finalization and recovery state machines using the other portable targets through explicit interfaces. |
| FLPersistence | GRDB records, migrations, repository adapters and single-transaction command execution. Depends on the portable targets, never SwiftUI/UIKit. |
| FLRecipeDelivery | Bundle manifest validation, adoption/install planning and revision comparison. Depends on FLDomain; commits go through FLPersistence. |

The target list is conditional. Do not add empty modules merely to satisfy this table. E01 must show that GRDB and the chosen SQLite configuration build on the intended Linux image. The checked-in vendored GRDB is not permission to fork it. If GRDB fails on Linux, ask the lead whether to change its version/configuration or use another adapter; do not silently replace persistence.

Keep `apps/ios` as the native host, with App for composition, Feature for views and Apple adapters under Platform/Integration/Capability. FeatureLogic remains a transition module until its owned logic is moved. UIKit image conversion, OS logging, Vision, AVFoundation, HealthKit, notification centers and credentials belong in adapters. Pure tests import the production target, not copied files or pretend Apple types.

Proposed persistence additions are append-only preference events and exposure rows, model/feature snapshots, durable action proposals/receipts, cooking checkpoints and timers, recipe revisions with source/rights/quantity evidence, community cache/outbox and a schema revision registry. Keep recipe-line identity separate from ingredient identity. Existing recipe/history/local IDs need a versioned mapping to external source keys. One migration owner reserves identifiers and freezes SQL ordering after the integration cut. Reject unsupported future formats; never silently reset a user's database on migration failure.

Retain the existing inventory ledger and historical snapshot ownership. Meal history, consumption attribution, preference cook event and nutrition snapshot should commit together; HealthKit and community synchronization use after-commit retry state. Do not turn every repository call into distributed synchronization. A failed network request must not undo a locally logged meal or publish private state by accident.

CI should run CPU-only Swift target tests, backend typecheck/tests and deterministic Python checks on Linux; then macOS CI compiles and runs hosted iOS tests on the actual integration head. Limit Swift parallel jobs to fit 8 GB and shard independent suites only after measuring memory. Avoid invoking provider models or downloading image corpora in required PR gates. Native gate failures remain blockers for the affected delivery, even when the Linux logic passes.

### Goal 6. UI redesign package boundary only

**Option A, recommended.** `packages/FLDesignTokens` stores semantic token definitions and nonvisual policy values using portable types. `packages/FLDesignSystem` imports those tokens and implements SwiftUI renderers/components. FLDesignSystem is Apple-only and compiled by macOS CI; Linux never treats a skipped target as a successful UI build. Native views consume portable flow state and send typed intents.

**Option B.** Keep the current DesignSystem folder in the host but feed it validated token data. Less wiring now, weaker enforcement against feature-specific drift. Suitable as a transition, not a claim that the redesign is complete.

**Option C.** Make one SwiftUI package with conditional Linux placeholders. Not recommended. Placeholder types can make tests pass while hiding broken renderers.

This document selects no visual direction. The lead's design spec owns colors, typography, navigation, accessibility presentation and motion. The token package can check schema, semantic role coverage and approved values; it cannot prove that the application looks good. Camera components are platform adapters, not generic design-system tokens. Any native design execution must use the user's required design/motion skills and a real native review before shipment.

## 4. Feasibility and risks

| Goal | Feasible first result in Linux | Main risk and required outside evidence |
| --- | --- | --- |
| Community | Auth verifier fixtures, repository API, transaction/ownership cases, report/block/deletion rules and offline sync reducers. | Product cut, auth/storage provider and moderation ownership need lead decisions. Real Apple sign-in, deployed IAM, deletion across backups and public abuse operations remain unverified. Do not launch public writes without them. |
| Preference learning | CPU-only deterministic features/model, simulated users, held-out replay where consented logs exist, restrictions and reset tests. | No real user dataset or chosen improvement target was supplied. Simulated success does not prove preference quality. Exposure bias can make a model seem better than it is. |
| LeChef | App-state tools/proposals, workflow transitions, restart/idempotency and fake-provider protocol tests. | Real Gemini session behavior, camera/audio capture, interruption, latency, timers during suspension and human food-safety interpretation need native/provider checks. |
| Recipes | Rights manifest validation, local fixture parsing, resolver/quantity/nutrition tests, dedupe, quality report and deterministic bundle build. | Rights and human cooking quality cannot be decided by a sandbox. Existing BBC attribution is not licensing. Size/coverage claims remain hypotheses until approved sources yield usable records. |
| System quality | Actual portable target builds, migrations from frozen databases, compensation/retry scenarios, query/corpus performance. | GRDB portability is not yet proven for the new arrangement. Existing PR conflicts and data migrations precede extraction. macOS compile/tests and real HealthKit/notifications still gate the host. |
| UI boundary/redesign | Token schema, dependency checks, flow reducers and source-resource inventory. | Linux cannot compile SwiftUI, screenshot, judge aesthetics or exercise VoiceOver/Dynamic Type/Reduce Motion. macOS compile is necessary, not sufficient. Human/native review remains mandatory. |

Use three evidence labels: `verified-linux` for a command executed against the named production artifact, `verified-native-ci` for actual macOS CI results at that artifact, and `unverified-native` for runtime/native checks not executed. Source inspection and planned checks have neither verified label. Emulators and fake providers establish their tested contracts, not deployment readiness.

## 5. Conditional task breakdown

### Preconditions and ownership rules

The lead must approve the recommended product cut and contracts before dispatch. The safety/product integration in section 2 is a prerequisite handled by existing PR writers and Sam's authorized integration owner, not a parallel task with blanket ownership over every future file. Recover writer handoffs for #44/#45/#56/#71 before anyone edits their code.

There are 27 proposed tasks. Each is a substantial implementation plus regression/evaluation job, not a file-renaming ticket. Paths below are proposed and repository-relative. Each task owns its source, tests and fixtures only in the listed directories. Another task may read them but not edit them. Where tasks share a package, they own different subdirectories; only E01 owns that package's manifest. No task edits another task's dependency manifest. Existing source remains read-only to package tasks until the host owner replaces its callers, preventing duplicate native writers.

All branches use `overhaul/E##-<slug>`. Base branches are frozen integration cuts: W1 uses `integration/overhaul-20261011-w0`; W2 uses `...-w1`; W3 uses `...-w2`; W4 uses `...-w3`; W5 uses `...-w4`. Every cut includes the preceding wave's accepted dependencies. Same-wave tasks do not depend on one another. The lead or Sam's authorized integrator publishes the cuts; tasks do not merge siblings or main. An unresolved contract stops that dependent task, not the independent wave.

These acceptance commands name proposed checks. They are not commands already run or existing scripts. E01 creates `scripts/overhaul-checks/check.py`, which runs only the target IDs requested, refuses absent suites and records source/build identity. Every task exposes its actual test invocation to that checker. Package tasks use `swift test --package-path packages/FridgeLuckCore --jobs 4` with appropriate filters; Python and Bun tasks use pinned project environments and bounded fixtures. E25 never claims portable SwiftUI compilation. Missing native tools remain explicit acceptance gaps.

### Wave 1. Contracts and executable foundations

**E01, portable build and CI ownership.** Base W1; branch `overhaul/E01-build-gates`; depends_on none beyond the lead's approved target list. Own `packages/FridgeLuckCore/Package.swift`, `packages/FridgeLuckCore/Package.resolved`, `.github/workflows/`, `scripts/overhaul-checks/`, `project.yml`, and the transitional `apps/ios/Package.swift`/`Package.resolved`. Establish Linux builds of actual GRDB-backed production targets, target dependency rules, pinned backend/data gates and macOS host builds. Acceptance: `check.py E01` proves a minimal production database transaction/migration on Linux, rejects a forbidden Apple import and a missing test suite, and runs backend/data checks without credentials. Later manifest/host wiring is this same owner's reserved continuation, not another task's files. `unverified-native`: iOS compile/test until the resulting GitHub job executes, device behavior always separate.

**E02, domain contracts and compatibility fixtures.** Base W1; branch `overhaul/E02-domain-contracts`; depends_on lead approval of IDs, quantity unknowns and event semantics. Own `packages/FridgeLuckCore/Sources/FLDomain/` and `Tests/FLDomainTests/`. Define validated value types for recipe/source revisions, FDC/local identity, nutrition units, restrictions, events, proposals and command/results. Freeze fixtures usable by Swift, TypeScript and Python without assuming one decoder. Acceptance: `check.py E02` rejects nonfinite/negative quantities, unknown schema versions and mismatched revisions; round-trips valid fixtures and preserves unknown evidence. `unverified-native`: legacy model integration.

**E13, licensed source acquisition.** Base W1; branch `overhaul/E13-recipe-sources`; depends_on lead-approved rights sources. Own `scripts/recipe_pipeline/sources/`, `scripts/recipe_pipeline/tests/sources/`, `scripts/recipe_pipeline/rights/`, and `scripts/recipe_scraper/`. Carry #43 regressions into deterministic source adapters with explicit attribution/rights and quarantine. Use frozen approved samples, never unauthorized bulk downloads. Acceptance: `check.py E13` rejects missing/expired/incompatible permissions, malformed recipes and missing required raw lines; repeats acquisition on fixtures identically and runs #43 tests. `unverified-native`: none; legal approval and live source access remain separate unverified dependencies.

**E24, portable design-token contract.** Base W1; branch `overhaul/E24-design-tokens`; depends_on the lead's token contract, not a visual decision by this task. Own `packages/FLDesignTokens/`. Implement semantic token types, validation and export/compatibility fixtures from approved values. Acceptance: `check.py E24` runs Swift tests on Linux, rejects incomplete role sets and unsupported versions, and checks deterministic export. Do not invent or tune visual values. `unverified-native`: rendered contrast, typography, layout and motion.

### Wave 2. Independent core capabilities

**E03, local persistence and migration authority.** Base W2; branch `overhaul/E03-persistence`; depends_on E01,E02 and accepted #44/#45/#56 migration order. Own `packages/FridgeLuckCore/Sources/FLPersistence/` and `Tests/FLPersistenceTests/`. Implement GRDB records, schema registry, event/model/proposal stores and transaction adapters against the approved domain contracts. Preserve old database fixtures and snapshot provenance; reserve migration IDs centrally. Acceptance: `check.py E03` upgrades fresh and frozen installed databases, rejects future schemas, rolls back injected failures, and proves atomic meal/history/snapshot/consumption/event writes with duplicate command IDs. `unverified-native`: Application Support paths, file protection and host launch.

**E04, inventory mutation and compensation engine.** Base W2; branch `overhaul/E04-inventory-core`; depends_on E01,E02 and the existing compensation owner's accepted behavior. Own `packages/FridgeLuckCore/Sources/FLInventoryCore/` and `Tests/FLInventoryCoreTests/`. Extract intake/lot allocation/consumption/compensation as deterministic command planning, preserving attribution and unknown amounts. Acceptance: `check.py E04` runs seeded invariants over log/correct/delete/retry/later-consumption sequences; no double stock restoration, negative remaining mass or fabricated quantity. `unverified-native`: grocery review and native correction adapters.

**E05, recipe evidence, nutrition and hard filters.** Base W2; branch `overhaul/E05-recipe-core`; depends_on E01,E02. Own `Sources/FLRecipeCore/Evidence/`, `Sources/FLRecipeCore/Nutrition/`, `Sources/FLRecipeCore/Feasibility/` and matching subdirectories under `Tests/FLRecipeCoreTests/`, all inside `packages/FridgeLuckCore/`. Implement quantity-aware feasibility, nutrition coverage and allergy/diet filtering over complete ingredient lines. Acceptance: `check.py E05` proves sodium unit conversions, serving scaling, raw/cooked identity refusal, unresolved-line abstention and exact/unknown quantity semantics against independent arithmetic fixtures. `unverified-native`: display formatting and ingredient-review presentation.

**E06, preference events and feature reduction.** Base W2; branch `overhaul/E06-preference-features`; depends_on E01,E02. Own `Sources/FLPreferenceCore/Events/`, `Sources/FLPreferenceCore/Features/` and corresponding `Tests/FLPreferenceCoreTests/` subdirectories inside the core package. Build deterministic event validation, exposure linkage, retraction reduction and recipe/user features. Acceptance: `check.py E06` proves replay/order rules, duplicate events, cancellation, sparse users and no post-cutoff features; migrations of old counts remain labelled aggregates rather than fabricated logs. `unverified-native`: actual interaction instrumentation.

**E10, assistant authorization core.** Base W2; branch `overhaul/E10-assistant-core`; depends_on E01,E02. Own `Sources/FLAssistantCore/` and `Tests/FLAssistantCoreTests/` inside the core package. Implement typed read/write tool policy, approval binding, stale-state refusal and receipts independent of model prose. Acceptance: `check.py E10` rejects forged approval, altered payloads, wrong session/owner, expired proposals, unsupported tools and duplicate execution; fake receipt claims never mutate an app command store. `unverified-native`: mounted approval prompts and live voice intent.

**E12, cooking and recovery state machines.** Base W2; branch `overhaul/E12-flow-core`; depends_on E01,E02 and accepted #83 checkpoint semantics. Own `Sources/FLFlowCore/` and `Tests/FLFlowCoreTests/` inside the core package. Implement durable cook/resume/finalize/timer state with deliberate resume and one finalization command; consume #83 behavior without changing its original writer's branch. Acceptance: `check.py E12` exercises crash/restart, changed recipe revision, corrupt checkpoint, timer reconciliation and repeated finalization with a fake command executor. `unverified-native`: background timers, notifications and navigation.

**E14, ingredient and quantity resolution pipeline.** Base W2; branch `overhaul/E14-recipe-resolution`; depends_on E02,E13. Own `scripts/recipe_pipeline/resolution/` and `scripts/recipe_pipeline/tests/resolution/`. Resolve all recipe lines to FDC/preparation identities with approved aliases and household-measure evidence; retain unresolved lines and repeated uses. Acceptance: `check.py E14` catches egg/eggplant, raw/cooked mismatches, ambiguous aliases, missing density and repeated lines; every resolved amount has evidence, no generic 50 g fallback. `unverified-native`: none; real-world measure accuracy beyond evidence remains unverified.

**E18, community publication core.** Base W2; branch `overhaul/E18-community-core`; depends_on E01,E02 and approved community scope. Own `Sources/FLCommunityCore/Publication/` and `Tests/FLCommunityCoreTests/Publication/` inside the core package. Define publication previews, recipe revisions, license declarations, visibility intents and redacted DTO validation. Acceptance: `check.py E18` proves no pantry/health/preferences leak into publication, source attribution survives and edited drafts require a new publication revision. `unverified-native`: share preview and sign-in interaction.

**E19, backend account authentication.** Base W2; branch `overhaul/E19-community-auth`; depends_on E02 and lead-approved auth provider/session model. Own `backend/gemini-agent/src/community/auth/` and `src/__tests__/community-auth/`. Implement token verification, account/session ownership, revocation and server moderator roles. Refresh current provider docs first; no custom cryptographic verifier or unapproved dependency. Acceptance: `check.py E19` tests issuer/audience/nonce/expiry/signature errors, replayed exchanges, revoked sessions, caller-supplied owner IDs and moderator escalation with local fixtures and provider emulator where supported. `unverified-native`: real Apple login and deployed IAM/secrets; absent emulator verification is a recorded gate, not bypassed.

**E21, moderation and privacy rules.** Base W2; branch `overhaul/E21-community-policy`; depends_on E02 and lead approval of moderation operator/retention/deletion policy. Own `backend/gemini-agent/src/community/moderation/` and `src/__tests__/community-moderation/`. Implement report/block/review/withdraw transitions, visibility decisions and deletion plans as pure server policy. Acceptance: `check.py E21` tests blocked-author visibility, report abuse bounds, unauthorized moderation, deleted content and idempotent deletion plans. No LLM-only publication approval. `unverified-native`: none; human moderation capacity and actual storage deletion remain external gates.

**E25, native design-system renderer boundary.** Base W2; branch `overhaul/E25-design-renderers`; depends_on E24 and the lead's native component specification. Own `packages/FLDesignSystem/`. Package native components without feature business logic or Linux stand-ins; preserve approved accessibility and reduced-motion behavior. Acceptance: `check.py E25` validates token bindings, resource references and dependency restrictions on Linux, explicitly reports Apple compilation not run, and requires macOS package compilation before acceptance. `unverified-native`: all visual quality, accessibility runtime, animation and device rendering. This task requires a separate native/design-capable owner; Linux alone cannot finish it.

### Wave 3. Models, services and delivery

**E07, local preference model.** Base W3; branch `overhaul/E07-preference-model`; depends_on E06,E02 and lead-approved learning objective. Own `Sources/FLPreferenceCore/Model/` and `Tests/FLPreferenceCoreTests/Model/` inside the core package. Implement bounded regularized learning, shrinkage, deterministic snapshots, reset and fallback. Acceptance: `check.py E07` verifies training-cutoff integrity, replay equivalence, finite coefficients, cold-start fallback, deliberate dislike semantics and shift adaptation on fixed examples. No improvement claim until E09. `unverified-native`: device learning cost and user satisfaction.

**E08, constrained recommendation ranking.** Base W3; branch `overhaul/E08-ranking`; depends_on E05,E06. Own `Sources/FLRecipeCore/Ranking/` and `Tests/FLRecipeCoreTests/Ranking/` inside the core package. Build deterministic candidate ranking with an injected preference scorer, complete/near-match tiers and machine-readable reasons. It may use the fixed baseline until E07 lands. Acceptance: `check.py E08` verifies restrictions before scoring, stable ties, quantity insufficiency, diversity constraints approved by the lead and baseline parity on frozen candidates. `unverified-native`: result ordering and explanations in the app.

**E11, backend app-state tools.** Base W3; branch `overhaul/E11-agent-tools`; depends_on E10,E12,E05 and approved authority model. Own `backend/gemini-agent/src/appTools/` and `src/__tests__/app-tools/`. Implement bounded snapshot reads and proposed app actions/receipts, using fake model transport and explicit unknowns. Acceptance: `check.py E11` tests stale/reordered/duplicated calls, recipe-text instruction attacks, cancellation and refusal to treat the server ledger as the phone's inventory. `unverified-native`: actual Gemini Live interoperability and latency.

**E15, audited nutrition enrichment.** Base W3; branch `overhaul/E15-nutrition-pipeline`; depends_on E14,E05 and accepted #40 corrections. Own `scripts/data/`, `scripts/recipe_pipeline/nutrition/` and `scripts/recipe_pipeline/tests/nutrition/`. Preserve canonical FDC provenance, emit typed quantity/nutrient coverage, and generate corrected USDA artifacts without silently changing historical snapshots. Acceptance: `check.py E15` replays approved reference fixtures, byte-compares regenerated SQLite exports, proves per-100 g/serving/sodium arithmetic and refuses unsupported yield/density claims. Existing #40 tests run here. `unverified-native`: catalog hydration and display, not reference arithmetic.

**E17, safe bundle installation.** Base W3; branch `overhaul/E17-bundle-delivery`; depends_on E03,E05,E14 and accepted #44/#45 ownership contracts. Own `Sources/FLRecipeDelivery/` and `Tests/FLRecipeDeliveryTests/` inside the core package. Implement manifest/revision validation and transactional installation through FLPersistence interfaces, including edited-user-content preservation and historical-readiness refusal. Acceptance: `check.py E17` tests unchanged/changed bundles, bad hashes, removed entries, same-title user recipes, interrupted installs and unchanged historical nutrition. `unverified-native`: app resource packaging and launch readiness.

**E20, community content repository/API.** Base W3; branch `overhaul/E20-community-content`; depends_on E19,E18,E21. Own `backend/gemini-agent/src/community/content/` and `src/__tests__/community-content/`. Implement approved recipe/challenge/submission/save endpoints with account authorization, moderation policy and a storage adapter. Acceptance: `check.py E20` runs durable-store/emulator transactions for two-user access, revision conflicts, duplicate submissions, stable pagination, blocked/withdrawn content and deletion retries. Fake-store-only success does not accept the storage adapter. `unverified-native`: deployed database IAM/indexes and human abuse handling. Media remains excluded unless the lead approves another bounded task.

**E22, community synchronization core.** Base W3; branch `overhaul/E22-community-sync`; depends_on E03,E18,E19. Own `Sources/FLCommunityCore/Sync/` and `Tests/FLCommunityCoreTests/Sync/` inside the core package. Implement account-bound cache/outbox planning, offline drafts, revision conflicts and sign-out cleanup using injected transport/storage. Acceptance: `check.py E22` tests retry/restart, duplicate acknowledgements, account switching, unauthorized publication and redacted wire payloads. `unverified-native`: actual credential storage and network/background behavior.

### Wave 4. Corpus, evaluation and host adapters

**E09, preference evaluation and activation gate.** Base W4; branch `overhaul/E09-preference-eval`; depends_on E07,E08,E06. Own `evaluation/preference-learning/`. Build a Linux runner that imports actual production package modules, fixed simulated users, optional consented replay and non-writing report verification. Acceptance: `check.py E09` compares the four stated baselines, detects future-label leakage and altered/missing artifacts, reports grouped scenario counts and checks the lead's predeclared improvement/regression threshold with zero restriction violations. No real-user replay claims if no authorized logs exist. `unverified-native`: user satisfaction and device performance.

**E16, corpus quality and release artifact.** Base W4; branch `overhaul/E16-recipe-release`; depends_on E13,E14,E15,E17. Own `scripts/recipe_pipeline/delivery/`, `scripts/recipe_pipeline/tests/delivery/` and `apps/ios/Resources/data.json`, `apps/ios/Resources/usda_ingredient_catalog.sqlite`, plus new `apps/ios/Resources/RecipeCorpus/`. Own generated app resources, not E15's canonical source. Build dedupe groups, reviewable quality reasons and versioned bundle artifacts. Acceptance: `check.py E16` repeats builds identically, rejects unknown rights/incomplete recipe claims, validates every reference/hash, reports accepted/rejected counts and meets the lead's approved corpus/coverage target. Never alter pinned LegacyBundles. `unverified-native`: install/startup resource delivery and human cooking quality; the latter is a release sample gate.

**E26, native host integration and thin views.** Base W4; branch `overhaul/E26-native-host`; depends_on E03-E08,E10-E12,E17-E18,E22,E25 and the lead's approved UI flows. Own legacy source files under `apps/ios/App/`, `Feature/`, `FeatureLogic/`, `Domain/`, `Capability/`, `Platform/`, `Integration/`, `DesignSystem/` and `Tests/` that exist at the w0 cut. It owns no package or Resources files and no Tools research package. Freeze an exact file inventory before dispatch; newly added native adapter/tests in those host directories also belong here. Replace concrete old callers with package imports, route every finalization through the single transaction, instrument real exposure/outcome events, connect community draft/approval and assistant receipts. Do not rewrite all screens in this one task: apply the approved flow adapters and leave visual implementation with the lead's separately scoped native plan. Acceptance: `check.py E26` runs source dependency/adapter contracts and fake transport scenarios on Linux; macOS CI must compile and exercise production adapters. `unverified-native`: mounted journeys, VoiceOver, Dynamic Type, Reduce Motion, camera/mic, HealthKit, permission recovery and human UI review. Linux delivery is partial until those gates run.

**E27, backend host wiring and production-boundary checks.** Base W4; branch `overhaul/E27-backend-wiring`; depends_on E11,E19-E21 and accepted #39/#24. Own the existing files at w0 under `backend/gemini-agent/src/` outside E11's `appTools/`, E19-E21's `community/` and their test directories; also own `backend/gemini-agent/package.json`, lockfile, tsconfig, Dockerfile, configuration examples and deployment definition files. New legacy-host tests belong to this owner outside reserved test directories. Compose identity, content and app-tool routers, preserve #39 safety/retention, replace main's authority leaks and keep account-bound transient context separate from durable app state. Acceptance: `check.py E27` runs Bun typecheck/full tests, real loopback HTTP/WebSocket fake-provider scenarios, restart/account isolation, size/rate bounds and no private frames/text in durable content or logs. Build the image without deploying. `unverified-native`: live provider, Cloud Run IAM, production secrets and actual push delivery.

### Wave 5. Collective acceptance

**E23, system scenarios and performance proof.** Base W5; branch `overhaul/E23-system-checks`; depends_on E09,E16,E26,E27 and all prior integrated tasks. Own `evaluation/system-overhaul/`. Build end-to-end Linux scenarios using actual portable persistence/commands, backend loopback API and released bundle, not duplicated reference implementation. Acceptance: `check.py E23` proves fresh install, installed-data upgrade, recipe choice/cook/log/correct/delete, learning replay/reset, assistant approval/retry and community publish/report/block/delete with two accounts. Inject transaction/network failures and assert no double effects or privacy leaks. Measure candidate retrieval, bundle install, memory and model update at the approved corpus size within the sandbox budget; the lead sets device budgets separately. `unverified-native`: all real iOS journeys, visual review, provider session and deployment. Publish a precise gap list rather than call Linux scenarios a native E2E pass.

### Stop and handoff conditions

A task is done when its named checks run against its production artifact, results include exact identity, reserved files remain untouched, and native/external gaps are recorded. The whole overhaul is not done at that point. The integration owner needs collective Linux results, macOS hosted results, migration/data invariants, rights approval and the lead's native/product acceptance. No task can turn an unavailable check into a pass.

Before dispatch, the lead must resolve these choices:

- Community first-release behaviors, account/provider choice, media exclusion, moderation operator and retention/deletion policy.
- Local-only preference default, approved objective and simulated/replay activation thresholds.
- Phone-authoritative LeChef tools versus synchronized server-authoritative household state.
- Approved recipe licenses, retained existing content, corpus-size/coverage target and human cooking sample.
- The target/package graph, GRDB portability fallback and migration order after #44/#45/#56 reconciliation.
- Native design/component spec, macOS CI ownership and who performs runtime/human acceptance.

No additional worktree, merge, deployment, issue creation or original PR writer replacement is authorized by this plan. Existing writer ownership transfers must be explicit. The lead may accept the current-state evidence independently of any architecture recommendation.
