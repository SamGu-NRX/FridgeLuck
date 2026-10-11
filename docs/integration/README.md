# App integration trunk

Branch `fleet/fl-trunk-20261011` (programme `fl-integration-f1`, part 1). It folds the
fleet's product PRs into `alpha` as real `--no-ff` merges. This draft PR exists so macOS
iOS CI runs on the composed result. Nothing here merges into `alpha` or `main` by itself.

## Documents

- [PR-LEDGER.md](PR-LEDGER.md) — one row for every open PR: verdict and reason. Sam reads
  this to decide what merges after review.
- [CONFLICTS.md](CONFLICTS.md) — every merge conflict on this trunk, both sides, and the
  resolution with its evidence.

## Fold order

1. Alpha's head (`2e779381bb39`) already contains the minimal-product stack (#4 #5 #7 #8 #9 #11 #12 #13).
2. #23 `fix/intake-inference-semantics`
3. #15 `obv/fridgeluck-tour-dismiss-race`
4. #28 `obv/fridgeluck-013`
5. #35 `obv/fridgeluck-042` (the trunk brief wrote "#34"; the branch+SHA identify PR #35 — see CONFLICTS.md C3)
6. #36 `obv/fridgeluck-046`
7. #37 `obv/fridgeluck-056`
8. #32 `obv/fridgeluck-001` (explicit allergen groups, v19 migration)
9. #33 `obv/fridgeluck-040` (confidence signals into FLFeatureLogic)
10. #6 `fix/notification-settings-sendable`
11. #18 `obv/fridgeluck-054` (workflow-only; held per Sam's standing rule — staged under `ci/pending-workflows/`)
12. #31 `obv/fridgeluck-033` (only if it merges cleanly; a conflict excludes it)

## Doctrines on this trunk

- Workflow files are never pushed. If a fold would change `.github/workflows/`, the merge
  keeps them, then a follow-up commit restores the base state and stages the held diff
  under `ci/pending-workflows/` with a first-line comment giving purpose and trigger.
- Published GRDB migrations are never renumbered or renamed. The resulting migration
  order is recorded in the ledger.
- Contributing PR branches are read as fetched refs only; their heads are merged, never
  edited. If a head moves mid-work, the trunk merges the new head and records the SHA.
- Linux SwiftPM results on `apps/ios` are advisory. At the alpha baseline
  (`2e779381bb39`) the package already fails to build on Linux
  (`FeatureLogic/Assistant/LiveAssistantPanelLayout.swift` imports `CoreGraphics`; a few
  test files import `Vision`, `UIKit`, `SwiftUI`, `CoreImage`). The trunk tracks each
  fold's error set against that baseline and attributes new errors; macOS iOS CI on this
  PR is the authoritative build gate.
