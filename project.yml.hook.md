# project.yml hook — running the FLDesignSystem render tests in iOS CI

## What this is

The **exact diff** to apply to the repo's `project.yml` so the FLDesignSystem
render tests run inside the **existing** FridgeLuckTests target — the one
`.github/workflows/ios-ci.yml` already builds and runs on macos-26 via
`scripts/run_ios_tests.sh`. No workflow file changes: iOS CI picks these tests
up the moment the project regenerates.

This file is a **proposal** (`project.yml.hook.md`), not an applied edit —
`project.yml` is integration configuration, and this delivery never touches
the repository. Apply it when the packages land.

## The diff

Against `project.yml` as it stands on the design-system base
(`fleet/fl-trunk-20261011` @ `a5ac7c7`; identical shape on the branch this
delivery targets):

```diff
--- a/project.yml
+++ b/project.yml
@@ packages
 packages:
   GRDB:
     url: https://github.com/groue/GRDB.swift.git
     from: 7.10.0
+  FLDesignTokens:
+    path: packages/FLDesignTokens
+  FLDesignSystem:
+    path: packages/FLDesignSystem
 
@@ targets.FridgeLuckTests
   FridgeLuckTests:
     type: bundle.unit-test
     platform: iOS
     deploymentTarget: "26.0"
     sources:
       - path: apps/ios/Tests
+      - path: packages/FLDesignSystem/Tests/FLDesignSystemTests
     dependencies:
       - target: FridgeLuck
       - target: FLFeatureLogic
       - package: GRDB
         product: GRDB
+      - package: FLDesignTokens
+      - package: FLDesignSystem
```

Three insertions, nothing removed:

1. **`packages:` map** — registers both local packages by `path:`. XcodeGen
   emits them as local SwiftPM package references; `./scripts/ensure_xcode_project.sh`
   (already a CI step) regenerates the xcodeproj with them.
2. **`FridgeLuckTests.sources`** — compiles
   `packages/FLDesignSystem/Tests/FLDesignSystemTests/RenderTests.swift`
   into the test bundle, alongside the existing `apps/ios/Tests` sources.
3. **`FridgeLuckTests.dependencies`** — links the two package products so
   `@testable import FLDesignSystem` / `import FLDesignTokens` resolve.
   Local package entries carry no `product:` key (the product defaults to the
   package name); only the remote GRDB entry needs one.

After applying: `./scripts/ensure_xcode_project.sh && ./scripts/run_ios_tests.sh`
locally, or just push — iOS CI does both already.

## What runs where once hooked

| Suite | Where | Effect |
|---|---|---|
| FLDesignTokens (20 tests) | Linux job (`swift test`) + any Mac | WCAG ratios, completeness, invariants |
| RenderTests — full matrix (24 states + skipped sheet test) | **iOS simulator, FridgeLuckTests, existing iOS CI** | every state renders, PNGs land in the simulator tmp dir |
| RenderTests — contact sheets | macOS only (`swift test` from a checkout, or the staged `ci/pending-workflows/design-system-renders.yml`) | sheets assemble + upload; on iOS this step `XCTSkip`s loudly |

`FL_RENDERS_DIR` is unset in iOS CI, so renders go to the simulator's tmp
dir and are discarded — the assertions are what matter there. The macOS
workflow exists to produce the PNGs people review.

## Conflict notes

- **`packages:` map** — if another task added a package entry (e.g. FLTaste,
  FLFoodSafety) at the same spot, re-apply the two blocks after the last
  package key; YAML maps are order-insensitive, so the insertions survive any
  neighbour. Watch indentation: two spaces under `packages:`, four under each
  package name.
- **`FridgeLuckTests.sources`** — if someone added another `- path:` line,
  append the design-system line after the last one; multiple source paths
  coexist. Do not remove `apps/ios/Tests` — the app's own tests live there.
- **`FridgeLuckTests.dependencies`** — additive; if another task added
  `- package: X` entries, keep them. The only shape rule: remote packages
  need `product:`, local ones do not.
- **If the app target integrates the packages first** (a later PR adding
  `FLDesignSystem` to `targets.FridgeLuck.dependencies`), these test-target
  entries stay as they are — the test bundle links the products directly, not
  through the app.
- **Upstream drift** — this diff was cut against `a5ac7c7`. If `project.yml`
  moved (new targets, renamed test target), re-cut the diff from the file as
  it stands then; the three insertions are stable in shape but their context
  lines may shift.
- **Duplicate compilation guard** — if a future change also adds the
  `Tests/FLDesignSystemTests` directory to a second target, RenderTests.swift
  compiles twice (duplicate class). Keep it in exactly one target.
- **Tools version** — the packages declare `swift-tools-version: 6.2`
  (required for `.iOS(.v26)`); Xcode 26.6's SwiftPM handles this alongside
  the app's `SWIFT_VERSION: 6.0` target settings. If an older Xcode ever
  builds the project, it will refuse the manifest — that is a floor, not a
  bug.

## Why hook into FridgeLuckTests instead of macOS-only

The render tests are the component package's only automated proof that every
component renders in every state. Running them in the test bundle iOS CI
already executes means: no new workflow, no new runner cost, and the matrix
is exercised on the platform the app ships for. The macOS workflow (staged
under `ci/pending-workflows/`) is purely for the human-reviewable artifacts.
