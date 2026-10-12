# CONFLICTS — integration trunk decisions

One entry per conflict met while folding. Format: the conflict, both sides, the resolution, why. Precedent discipline comes from the overhaul PLAN (the minimal-stack composition kept #5's side over #11 in `ReverseScanResultsSections.swift`).

## C1 — #31's invariant suite vs alpha's recipe-driven preview API

**The conflict.** Both sides change what `previewConsumption` is. Alpha's trunk (minimal-product stack, commits `601d827` + `f7e5a7b`) replaced the quantity-list API `previewConsumption(ingredientGrams:)` with a recipe-, servings-, portion- and swap-driven preview that derives and depletes the same requests as `applyConsumption` — sequential claiming across rows, including a swap onto an ingredient the recipe already uses. #31's GRDB invariant suite (based on the pre-trunk eval harness `f63affc`) tests against the old API and documents a "rows evaluated independently" divergence that the new preview no longer has. Merging #31 as published did not compile against the trunk (`previewConsumption(ingredientGrams:)` no longer exists).

**Both sides.**
- Keep alpha's production preview (product side): every other consumer of the API on the trunk uses it; it is the side macOS CI has been green on; it is strictly more precise (row results carry claimed balance through repeated requests).
- Keep #31's suite semantics (test side): it encodes the old API's independence claim and its helper mirrors that claim in how it pairs preview rows with results.

**Evidence.** Alpha's side: green `build-and-test` on alpha and on every trunk fold; production callers (`FLCookModeEngine`, `OperationLogCoordinator`, `FlActiveSessionStore`, `BaselineSettingsStore`) all use the recipe-driven form. #31's side: test-only code with no production caller of the old API left on the trunk; its suite was written before `601d827` landed (base `f63affc`).

**Resolution.** Keep the trunk's product side; re-point the suite on the trunk (commit `49d3d0e`). The seeded preview test now drives the same recipe/servings/portion/swaps inputs as the apply and additionally asserts the claimed balance falls 100 → 16 across repeated requests — an invariant the old API could not express. The property helper matches preview rows consumably (a repeated request compares against its own row) and treats a missing preview row as the documented nothing-in-stock case (omission contract: consumed 0, shortfall = full request). Result: `swift test` on Linux passes, including the 20.6 s seeded property suite `testSeededOperationSequencesHoldAllInvariants`. The old-API divergence clause was deleted from the suite header because it no longer describes anything true.

## C2 — #18's workflow delta is held, not dropped

Not a product conflict — a doctrine application, recorded here for traceability. #18 (`obv/fridgeluck-054`) proposes a rewrite of `.github/workflows/ios-ci.yml`. The merge took the PR's head (`95ea8ed`), then the trunk restored `.github/workflows/` to alpha's state (hold commit `adaa32e`, message states the delta is held per Sam's standing rule) and staged the proposal at `ci/pending-workflows/ios-ci.yml` with a first-line comment giving purpose (auto-detect SwiftPM for iOS CI), trigger (any PR into alpha, including drafts) and provenance (#18). The staged file's diff against the PR's version is empty; the restoration diff against alpha is empty. Only Sam can approve the workflow change.

## C3 — brief bookkeeping: fold entry "4. #34" identifies #35

The trunk brief's fold list entry "4. #34 (obv/fridgeluck-042 @ 4eb62954eb)" pairs PR number #34 with the branch and head SHA that belong to PR #35 (PR #34's own head is `obv/fridgeluck-041` @ `dcd0d65adc`, a privacy-manifest change). The fold took the explicit branch+SHA: the content on the trunk as merge `62647e6` (whose message says "#34"). PR #35's ledger row records the mapping; PR #34 was not folded and is marked needs-owner so Sam can decide it on its own merits. Recorded here so the merge message's "#34" is never read as the privacy-manifest PR.

## C4 — #45's migration-order expectation vs the trunk's v19 extension

**The conflict.** Folding #45 (`bc5ed75`) conflicted in `apps/ios/Tests/MigrationUpgradeTests.swift`: the trunk (after #32's v19) expected the last four applied identifiers ending at v19, while #45's branch expected the last five ending at v20_historical_nutrition_snapshots. A comment-only conflict in `OnboardingGatePolicyTests.swift` described the same two fixture columns with equivalent wording on both sides.

**Resolution.** Take #45's side in the migration test: the merged trunk carries #45's v20 by definition of the join, so the suffix(5)/v20 expectation is the only one that describes reality. The comment conflict took the trunk's wording (semantically identical). Evidence: root app package suite 16/16 on the merged head (`a50bf22`).

## C5 — Flow E double-applies v21 after the #44 fold (join decision)

**The conflict.** Not a git conflict — a composition conflict the join existed to catch. The historical-nutrition check package's Flow E fixture hand-applied a vendored copy of `v21_bundle_ownership` (extracted from #44's branch per its `PROVENANCE.md`, which stated the fixture "should be replaced by the merge" once #44 landed). After folding #44, the app migrator — staged into the package from the real tree by `Scripts/refresh.sh` — registers v21 itself, and the vendored second application failed with `duplicate column name: ownership_key`. Two related fresh-clone traps: the package does not build without running `Scripts/refresh.sh` first (a `cannot find 'NutritionSnapshotService' in scope` error masks the real cause on a cold cache), and `bundled-refresh-check/Scripts/refresh.sh` assumed a `Fixtures/` directory git does not track.

**Resolution.** Retired the vendored helper and the hand-apply (commit `d872801`): the fixture relies on the real migration sequence, per the helper's own documented retirement protocol; the real v21 body is byte-identical between the vendored source head `7dc2b21` and the merged head `c316f5f` (verified by diff). Added the missing `mkdir -p` to `bundled-refresh-check/Scripts/refresh.sh`. Evidence on the combined trunk head: historical-nutrition-check 14/14, bundled-refresh-check 23/23, root app package 16/16, scripts/data pytest 9/9, legacy bundle pin checker OK.
