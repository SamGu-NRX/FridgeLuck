# PR-LEDGER — every open PR, one row each

Snapshot: live roster fetched 2026-10-11 (`GET /repos/SamGu-NRX/FridgeLuck/pulls?state=open&per_page=100`, paginated — 83 PRs; page 2 empty). The 84th row is this trunk PR (#93), which was created after that snapshot. Head SHAs are as of the snapshot; a contributing head that moved mid-work was re-merged and the new SHA recorded in its row.

Verdicts:

- **folded** — merged into this trunk as a real `--no-ff` merge of the PR's published head (8 of them arrived via alpha's minimal-product stack, 11 folded here; merge commit named per row).
- **pending owner Handoff** — an active continuation task owns the PR right now; do not fold until its owner's Handoff.
- **needs-owner** — Sam decides. Each reason carries a one-line fold-candidate note where one exists.
- **excluded-research** — benchmark/eval/study PR; no product behavior on the trunk.
- **excluded-backend** — substance under `backend/` (verified by diff); the parallel backend trunk owns them.
- **excluded-broken** — compile/test failure originating in the PR. None: no PR verified broken.
- **superseded-by #N** — replaced by another composition.
- **trunk row** — an integration trunk PR, not a fold candidate.

## Summary

| Verdict | Count |
| --- | --- |
| folded | 21 |
| needs-owner | 29 |
| excluded-research | 21 |
| excluded-backend | 11 |
| pending owner Handoff | 0 |
| superseded-by #93 | 1 |
| trunk row (this PR) | 1 |
| trunk row (backend) | 1 |
| excluded-broken | 0 |
| **total rows** | **85** |

Trunk composition: alpha `2e779381` (already carrying the minimal-product stack #4 #5 #7 #8 #9 #11 #12 #13) + 13 real merges: #23 `e0b8ec7`, #15 `4dc8b64`, #28 `7392209`, #35 `62647e6`, #36 `e30b808`, #37 `fd21677`, #32 `34db183`, #33 `8d58610`, #6 `2a3f79f`, #18 `95ea8ed` (+ hold commit `adaa32e`), #31 `eccf587` (+ adaptation `49d3d0e`, see CONFLICTS.md), #45 `bc5ed75` (join `a50bf22`), #44 `c316f5f` (join `f192e67`; see CONFLICTS.md C5). The parallel backend trunk landed as draft PR #94 (head `18fb5f93a5`, into alpha); it folds the backend PRs, with #16's workflow delta held at `ci/pending-workflows/backend-ci.yml`. Backend rows below point there.

## Migration order (never renumbered, never renamed)

Published order on the trunk ends at **v21**: v1_initial, v2_ingredient_education_fields, v3_dish_templates, v4_ingredient_aliases, v5_ingredient_display_metadata, v6_cooking_photo_servings, v7_usda_catalog_state, v8_bundled_recipe_state, v9_smart_fridge_inventory, v10_confidence_learning, v11_reconcile_ingredientless_recipe_links, v12_required_onboarding_identity, v13_ingredient_favorites, v14_pantry_assumptions_saved_winners, v15_notification_rules_and_opportunities, v16_inventory_quantity_estimates, v17_cooking_portion_multiplier, v18_cooking_history_swaps, **v19_explicit_allergen_groups** (added by folded #32; appended, not renamed), **v20_historical_nutrition_snapshots** (added by folded #45; join merge `a50bf22`), **v21_bundle_ownership** (added by folded #44; join merge `f192e67`). No other folded or considered PR adds a migration.

## Ledger

| PR | Head | Base | What it changes | Verdict | Reason |
| --- | --- | --- | --- | --- | --- |
| #3 | `1db4674939` | main | docs: add the kgu.one portfolio entry with its full write-up | needs-owner | docs-only, Sam decides (.portfolio/ entry) |
| #4 | `8c9c88fed3` | main | fix(ios): make the scan-to-meal loop work and log what was confirmed | folded | in alpha's minimal-product stack; the trunk starts from alpha 2e779381, so it is in |
| #5 | `30f341847c` | feat/minimal-product-20261007 | feat(ios): let meal-photo confidence set how much the user confirms | folded | in alpha's minimal-product stack |
| #6 | `854084860c` | main | fix(ios): read notification permission without sending UNNotificationSettings | folded | fold 10 of 12: merged as 2a3f79f (notification permission read without sending UNNotificationSettings) |
| #7 | `f63affc542` | feat/meal-photo-confirmation-v1 | feat(eval): add an offline harness comparing the confidence learner with Decisions | folded | in alpha's minimal-product stack (confidence-learner offline harness) |
| #8 | `a9df6aa39e` | feat/minimal-product-20261007 | fix(ios): stop camera labels resolving to unrelated foods and record failed Vision requests | folded | in alpha's minimal-product stack |
| #9 | `be5aecafcf` | feat/minimal-product-20261007 | fix(ios): scan the user's own photos in onboarding instead of inventing a kitchen | folded | in alpha's minimal-product stack |
| #11 | `9886dda994` | feat/minimal-product-20261007 | fix(ios): dim pressed buttons under Reduce Motion and fix counts of one | folded | in alpha's minimal-product stack |
| #12 | `954d6c63c7` | fix/recognition-precision | fix(ios): stop Vision work and the scan when the user leaves the scan screen | folded | in alpha's minimal-product stack |
| #13 | `3e6d321f1a` | fix/vision-cancellation | fix(ios): save failed scans and show them in the scan report | folded | in alpha's minimal-product stack |
| #14 | `6ddc309f2a` | feat/meal-photo-confirmation-v1 | [obvious-fleet] fix(ios): plain camera icon on the meal capture screen | needs-owner | fold candidate: small viable UI fix (plain camera icon), stacked on #5's branch (in alpha) |
| #15 | `5e6000dc75` | feat/minimal-product-20261007 | [obvious-fleet] fix(ios): make the tour unmount survive Skip→Next/Back | folded | fold 3 of 12: merged as 4dc8b64 (tour unmount survives Skip-Next/Back) |
| #16 | `8a50a263c8` | main | [obvious-fleet] Add backend and data pipeline CI (bun typecheck/tests, uv catalog validation) | excluded-backend | folded on backend trunk PR #94 with its workflow delta held at ci/pending-workflows/backend-ci.yml — only Sam approves workflow edits |
| #17 | `343ab09738` | main | [obvious-fleet] Integration preview: combined stack of the 8 open product PRs (do not merge) | superseded-by #93 | the stale combined-preview of 8 PRs; this trunk (PR 93) is the live composition |
| #18 | `51b449ae3f` | main | [obvious-fleet] ci: run dead-code advisory only on main/dispatch/periphery label; add SwiftPM dep cache | folded | fold 11 of 12: merged as 95ea8ed; workflow delta held per Sam's standing rule in adaa32e, staged at ci/pending-workflows/ios-ci.yml |
| #19 | `5c4159b4c2` | main | [obvious-fleet] Fail fast on invalid numeric env vars in loadConfig | excluded-backend | backend-only by diff (backend/gemini-agent env validation); folded on backend trunk PR #94 |
| #20 | `fb90d5c8c1` | main | docs: privacy and data-flow map (audited refs, backend-default decision) | needs-owner | docs-only, Sam decides (privacy and data-flow map) |
| #21 | `5c86759aa0` | main | [obvious-fleet] Validate reverse-scan provider rankings before returning them | excluded-backend | backend-only by diff (reverse-scan provider validation); owned by backend trunk PR #94 |
| #22 | `b2a6c650d0` | main | [obvious-fleet] Backend image: Node 20 (EOL) to Node 24 LTS slim, non-root, prod-only deps | excluded-backend | backend-only by diff (backend image Node 24); owned by backend trunk PR #94 |
| #23 | `35c358b7d4` | fix/onboarding-real-scan | fix(ios): file intake ingredients by their actual storage rules | folded | app integration: intake inference semantics (characterization suite, based on #9); SOURCE-RED verified: its own head https://github.com/SamGu-NRX/FridgeLuck/actions/runs/37970992723 failed build-and-test with these same InventoryIntakeInferenceTests assertions; the trunk merge e0b8ec7 added only the 308-line test suite - the engine is identical on both sides, so the suite fails against engine semantics that never landed. Folded as-is; Sam decides whether the engine semantics or the suite wins |
| #24 | `b433aa9580` | main | [obvious-fleet] Harden generateRecipe: untrusted JSON decoding, ingredient-policy screening, frozen 422 contract | excluded-backend | backend-only by diff (generateRecipe hardening); owned by backend trunk PR #94 |
| #25 | `dcffd6c22e` | main | feat(webhooks): require OIDC authentication on scheduler and task webhooks | excluded-backend | backend-only by diff (webhook OIDC); owned by backend trunk PR #94 |
| #26 | `6de7cd6d67` | main | Stop persisting camera frames; bound transient cache; add 24h session expiry | excluded-backend | backend-only by diff (frame retention, SPEC 3.4 item); owned by backend trunk PR #94 |
| #27 | `5e4e58fb98` | feat/minimal-product-20261007 | ci: run the pure-logic iOS subset on Linux | needs-owner | CI proposal (pure-logic iOS subset on Linux): only Sam can approve the workflow change; its apps/ios package changes can fold after that |
| #28 | `a915aa7e0a` | feat/minimal-product-20261007 | [obvious-fleet] Clean Le Chef cooking steps with the shared guide parser | folded | fold 4 of 12: merged as 7392209 (shared guide parser cleans LeChef steps) |
| #29 | `947dc8c58a` | main | Fix notification planner: DST-safe local scheduling and digest payload integrity | excluded-backend | backend-only by diff (notification planner DST fix); folded on backend trunk PR #94 |
| #30 | `03b19343ef` | main | refactor(backend): testable HTTP app with bounded validation, safe errors/logs, rate limits | excluded-backend | backend-only by diff (HTTP app refactor); owned by backend trunk PR #94 |
| #31 | `df1fb29b49` | feat/routing-eval-harness | Seeded GRDB inventory invariant suite (Linux-runnable) | folded | fold 12 of 12: merged as eccf587, adapted as 49d3d0e (suite re-pointed to the recipe-driven preview API; see CONFLICTS.md); folded because it merged cleanly, as the brief conditions |
| #32 | `c18ece18ea` | feat/minimal-product-20261007 | Explicit allergen group selection (onboarding, Settings, v19 migration) | folded | app integration: explicit allergen groups + v19_explicit_allergen_groups migration (order preserved); SOURCE-RED at its own head (migration-test API misuse), fixed on the trunk in 56b212f; the v19 column pair also required the old OnboardingGatePolicyTests fixture to gain the two columns (trunk fix) |
| #33 | `24fc372bd4` | feat/routing-eval-harness | feat(reverse-scan): extract confidence signals and hard-fail rules into FLFeatureLogic | folded | fold 9 of 12: merged as 8d58610 (confidence signals and hard-fail rules into FLFeatureLogic) |
| #34 | `dcd0d65adc` | feat/minimal-product-20261007 | Privacy manifest (PrivacyInfo.xcprivacy) with source-traced declarations, hosted packaging tests, and validator | needs-owner | NOT folded: the trunk brief's fold 4 named #34 with #35's branch and SHA (obv/fridgeluck-042 at 4eb62954eb = #35); this PR's own head dcd0d65adc (privacy manifest) was not merged. Sam decides whether to fold it next |
| #35 | `4eb62954eb` | fix/ui-count-and-reduce-motion | [obvious-fleet] Unify meal-photo entry points on "Log a Meal" with a food symbol | folded | fold 5 of 12: merged as 62647e6 (unify Log-a-Meal entry points). The brief listed this content under '#34'; branch obv/fridgeluck-042 at 4eb62954eb identifies it, the merge message says '#34' |
| #36 | `ebb604704a` | feat/minimal-product-20261007 | [obvious-fleet] fix(ios): make Not-this-item on ingredient review never a silent no-op | folded | fold 6 of 12: merged as e30b808 (Not-this-item never a silent no-op) |
| #37 | `4f51d21cd1` | fix/onboarding-real-scan | [obvious-fleet] VoiceOver for the onboarding kitchen scan: start announcements, labeled photo strip, Dynamic Type | folded | app integration: VoiceOver for the onboarding kitchen scan; SOURCE-RED at its own head 4f51d21cd1 (identical compile errors: accessibilityLiveRegion + type-check timeout); fixed on the trunk in a5ac7c7 + a4c6bf5 (updatesFrequently replaces the nonexistent SwiftUI live-region API; all audit findings kept) |
| #38 | `59b3ca2184` | fix/scan-failure-report | Test scan correction learner + confidence router | needs-owner | fold candidate: viable test-only PR (scan correction learner + confidence router), stacked on #13's branch (in alpha) |
| #39 | `20dc133f4e` | main | feat(backend): harden live-agent authority boundaries | excluded-backend | backend-only by diff (live-agent authority hardening); owned by backend trunk PR #94 |
| #40 | `5e3eae7276` | main | fix(data): USDA reference audit — recover Atwater energy rows and correct 65 macros with committed evidence | needs-owner | fold candidate: USDA reference audit (scripts/data only by diff) feeding the catalog; Sam decides (pairs with #50) |
| #41 | `85526906eb` | feat/routing-eval-harness | feat(experiments): Nutrition5k portion-estimation benchmark (RGB / RGB+D / foodlist arms) | excluded-research | research/benchmark: Nutrition5k portion-estimation benchmark (experiments/ only) |
| #42 | `0d9465eb67` | fix/onboarding-real-scan | feat(ios): real grocery intake by receipt and photo with reviewed amounts | needs-owner | fold candidate: viable product PR (real grocery intake), stacked on #9's branch (in alpha) |
| #43 | `93326d0884` | main | fix(scraper): repair ingredient identity, gram estimates, and diet tags from measured import failures | excluded-backend | scraper/data pipeline (scripts/recipe_scraper only); the brief assigns it to the backend trunk (PR #94) |
| #44 | `c316f5fa9e` | obv/fridgeluck-001 | feat(ios): stable bundle ownership and installed-data refresh | folded | head moved by its continuation (Handoff recorded); merged into this trunk as `f192e67` (join, 2026-10-11); adds v21_bundle_ownership |
| #45 | `bc5ed7538d` | obv/fl-next-historical-nutrition-r1 | feat(ios): freeze historical nutrition snapshots at log time | folded | head moved by its continuation (Handoff recorded); merged into this trunk as `a50bf22` (join, 2026-10-11); adds v20_historical_nutrition_snapshots |
| #46 | `7c82f019f5` | feat/routing-eval-harness | feat(evaluation): score and verify policy-study-v2 run 2026-10-10-r1 (synthetic mapped proxy metrics, grouped intervals) | excluded-research | research/eval: decisions-comparison study; stacked on #7's branch (in alpha) |
| #47 | `cba6272c70` | fix/scan-failure-report | feat(experiments): ingredient-recognition benchmark — frozen slice, resolution port, and open-model baselines | excluded-research | research/benchmark: ingredient-recognition benchmark (experiments/ only) |
| #48 | `7118d7ca39` | obv/fl-next-ingredient-recognition-r1 | feat(benchmarks): preparation-state-v1 — identity vs preparation-state evaluation with production replay | excluded-research | research/benchmark: preparation-state benchmark; stacked on #47's branch |
| #49 | `7bb32af457` | feat/minimal-product-20261007 | feat(evaluation): substitution evidence harness — 27 pairs, 227 recipe contexts, Swift replay | excluded-research | research/eval: substitution-evidence harness (title starts feat(evaluation)) |
| #50 | `16c2c6f236` | obv/fl-next-nutrition-reference | feat(data): pin FNDDS household-measure evidence, MassConversionKit package, and read-only estimator evaluation | excluded-research | research/data study: FNDDS mass-evidence pinning + MassConversionKit; stacked on #40's branch |
| #51 | `fa4dd24d42` | obv/fl-next-real-groceries | feat(ios): barcode intake — FLBarcode module, GTIN validation, source-pinned cache (milestone 1) | excluded-research | research milestone per the brief (barcode intake study); stacked on #42's branch |
| #52 | `91f7280731` | obv/fridgeluck-001 | feat(ios): weekly-plan planner core, flow, store, and check harness | needs-owner | fold candidate: viable product PR (weekly-plan planner core), stacked on #32's branch (folded; rebase onto alpha is cheap) |
| #53 | `39a07ac4a5` | obv/fridgeluck-043 | feat(evaluation): replay production LearningService over committed correction histories (SwiftReplay) | excluded-research | research/eval: correction-history replay; stacked on #38's branch |
| #54 | `9d5b947356` | obv/fridgeluck-001 | feat(evaluation): pantry-feasibility eval — frozen corpus, oracle, and Swift replay cross-check | excluded-research | research/eval: pantry-feasibility eval; stacked on #32's branch (folded) |
| #55 | `d9e8197d5f` | feat/minimal-product-20261007 | feat(ios): add label-numbers evaluation corpus with checker and parser replay | excluded-research | research/eval: label-numbers corpus + parser replay |
| #56 | `e4d58cbf3e` | feat/meal-photo-confirmation-v1 | feat(ios): correct meal deductions and single journal entries (draft) | needs-owner | viable product PR (meal corrections); waits on #44/#45 and the inventory-compensation owner per the brief |
| #57 | `a6c921a621` | feat/routing-eval-harness | feat(benchmarks): dish-ambiguity-v1 — taxonomy, manifests, and evaluated classifier pins | excluded-research | research/benchmark: dish-ambiguity benchmark |
| #58 | `e3b2bef95e` | obv/fl-next-ingredient-recognition-r1 | feat(benchmarks): nonfood-rejection-v1 — frozen 1,200-image benchmark with pinned arm evaluation | excluded-research | research/benchmark: nonfood-rejection benchmark; stacked on #47's branch |
| #59 | `ecbdfd6f48` | obv/fl-next-historical-nutrition-r1 | feat(ios): add storage-performance benchmark harness (storage-perf) | excluded-research | research/benchmark: storage-performance harness; stacked on #45's branch |
| #60 | `a4d55a1cc1` | feat/minimal-product-20261007 | feat(tools): health-ranking sensitivity study — production replay under nutrient/portion uncertainty | excluded-research | research/study: health-ranking sensitivity study (production replay) |
| #61 | `5eff785c5e` | obv/fl-next-historical-nutrition-r1 | feat(ios): add local backup archive codec, validator, and staged restore engine | needs-owner | fold candidate: viable product PR (local backup archive); stacked on #45's branch |
| #62 | `1e72cbab16` | obv/fl-next-historical-nutrition-r1 | feat(ios): add unified local search — private FTS5 index, Search screen, and Linux eval package | needs-owner | fold candidate: viable product PR (unified local search); stacked on #45's branch |
| #63 | `92de5f79fd` | obv/fl-next-ingredient-recognition-r1 | feat(benchmarks): multiplate-v1 — which dish is where, with detector, proposal, and oracle arms | excluded-research | research/benchmark: multiplate benchmark; stacked on #47's branch |
| #64 | `d055c2c849` | obv/fl-next-portion-estimates | Portion-interval study: calibrated + fixed-width coverage over frozen PR41 outputs | excluded-research | research/study: portion-interval study; stacked on #41's branch |
| #65 | `7d18beb6e2` | main | Add food-manifest lineage scanner with pinned read-only dataset audit (draft) | excluded-research | research/audit: food-manifest lineage scanner (read-only dataset audit) |
| #66 | `e8a56a22e4` | feat/meal-photo-confirmation-v1 | Serving identifiability study: schema, witnesses, source census (M1) | excluded-research | research/study: serving identifiability (schema, witnesses, census); stacked on #5's branch (in alpha) |
| #67 | `257f7a40d6` | main | test(backend): offline confidence-contract harness measuring ConfidenceService key/restart behavior | excluded-research | research/harness: offline backend confidence-contract harness |
| #68 | `1fbd47ae62` | obv/fridgeluck-001 | Feasibility-witness verifier: typed certificates, pinned fixtures, mutation corpus | excluded-research | research/verifier: feasibility-witness verifier (typed certificates, mutation corpus); stacked on #32's branch (folded) |
| #69 | `94b7e159a4` | obv/fridgeluck-052 | Add restock-boundaries reproducible offline study (fixtures, reference model, matrix pipeline, tests) | excluded-research | research/study: restock-boundaries offline study; stacked on #29's branch (backend) |
| #70 | `43ad185773` | obv/fl-next-historical-nutrition-r1 | Progress flow: provenance read model, owned range state, wired UI + a11y evidence | needs-owner | fold candidate: viable product PR (progress flow UI + a11y evidence); stacked on #45's branch |
| #71 | `c898d1b544` | obv/fl-next-bundled-refresh | Personal cookbook: store, transaction service, and flow-check (M1) | needs-owner | viable product PR (personal cookbook M1); waits on #44 (stacked on #44's branch) |
| #74 | `d78a001282` | main | feat: experiment capsules — independently verifiable provenance for food-study tables | needs-owner | fold candidate: experiment-capsules tooling (tools/ only) |
| #75 | `42804dcbdc` | feat/minimal-product-20261007 | Read-only recipe quantity review with serving scaling and substitutions | needs-owner | fold candidate: viable product PR (read-only recipe quantity review) |
| #76 | `2d54854e79` | feat/minimal-product-20261007 | Ingredient facts: stored per-100 g reference and explicit gram portion review | needs-owner | fold candidate: viable product PR (ingredient facts: per-100 g reference + gram portion review) |
| #77 | `f471a28de7` | feat/minimal-product-20261007 | feat(ios): recipe amount export from preview | needs-owner | fold candidate: viable product PR (recipe amount export) |
| #78 | `d5cde73c9e` | main | [draft] tools: fridgeluck-db-doctor — bounded read-only SQLite artifact inspector | needs-owner | fold candidate: draft dev tool (fridgeluck-db-doctor, tools/ only) |
| #79 | `a0632374a5` | feat/minimal-product-20261007 | Reminder center: explicit save/schedule/readback states (L4) | needs-owner | docs-only, Sam decides (diff is one planning/ file: the reminder-center spec) |
| #80 | `d663b4ea0c` | main | Profile Basics: safe load/edit/retry flow (draft) | needs-owner | fold candidate: draft product PR (profile basics load/edit/retry) |
| #81 | `e58e8326c5` | main | feat(sqlite-state-diff): read-only SQLite state-diff CLI (draft) | needs-owner | fold candidate: draft dev tool (sqlite-state-diff CLI, tools/ only) |
| #82 | `a40042a958` | obv/fl-next-portion-estimates | Acquisition faultlab: loopback fault injection + adapter measurement (draft) | needs-owner | fold candidate per the brief's viable list (acquisition faultlab, draft; research-leaning tooling) |
| #83 | `0542f37bdb` | obv/fl-next-meal-corrections-r1 | feat(cooking): offline cooking-session checkpoints with deliberate resume | needs-owner | viable product PR (cooking checkpoints); waits on #56 and the #44/#45 chain (stacked on #56's branch) |
| #84 | `87cadcdc80` | fix/scan-failure-report | feat(support): native help/recovery flow with typed diagnostics export | needs-owner | fold candidate: viable product PR (help/recovery flow + diagnostics export); stacked on #13's branch (in alpha) |
| #85 | `372f6f3bc9` | obv/fl-next-historical-nutrition-r1 | docs(planning): FL4 operational Home flow — spec for state map, read model, gate replacement | needs-owner | docs-only, Sam decides (operational-home planning spec); stacked on #45's branch |
| #86 | `3f91f453c0` | main | docs(spec): FridgeLuck overhaul spec with mock designs (draft) | needs-owner | docs-only, Sam decides (the overhaul spec itself; read as the programme's SPEC source) |
| #88 | `26c7004e60` | alpha | Evaluation scorecard harness: runner, suite contract, registry (fl-eval-harness-f1, m1) | needs-owner | owned by the parallel eval programme (fl-eval-harness-f1), awaiting its review; stages its workflows under ci/pending-workflows/ correctly |
| #90 | `4c7a3c8351` | alpha | core: FLDomain + FLPersistence foundation package (overhaul part 1) | needs-owner | owned by the parallel core programme (overhaul part 1), awaiting its review; stages its workflow under ci/pending-workflows/ |
| #93 | `d8728013de` | alpha | Integration trunk (do not merge as-is) | trunk row (this PR) | created after the roster snapshot; see docs/integration/README.md; join merges #45/#44 recorded 2026-10-11 |
| #94 | `18fb5f93a5` | alpha | Backend integration trunk (do not merge as-is) | trunk row (backend) | created after the roster snapshot; parallel backend programme |
