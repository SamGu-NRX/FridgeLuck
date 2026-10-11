# bundled-refresh-check

Linux-safe checks for the bundled-data ownership refresh, compiled against the
REAL production persistence sources (`apps/ios/Platform/Persistence`) and the
REAL bundled-refresh test suite (`apps/ios/Tests/BundledDataRefreshTests.swift`)
on GRDB, no Xcode required. This audits the full Linux-compilable persistence
surface — not a vendored subset — and runs the changed-bundle
`Double.bitPattern` invariance check (journal / daily chart / Apple Health
record doubles stay bit-identical across a bundle refresh).

## Run

```sh
bash Scripts/refresh.sh
bash Scripts/run.sh
```

`Scripts/refresh.sh` copies the real sources, the real test suite, and the
shipped bundle fixtures into this package (gitignored — never edit those
copies; edit the originals in `Platform/` and `Tests/`). `Scripts/run.sh`
builds, installs the fixtures where the Linux test runner's `Bundle.main`
resolves them (the equivalent of the iOS test host's app bundle), and runs
`swift test --skip-build`.

Apple-only sources are excluded: `AppleHealthService`,
`MealLogSyncCoordinator`, `ImageStorageService`, `MealLogService`,
`ConfidenceLearningService` (HealthKit, UIKit, os.log), and
`InventoryIntakeService` + `Detection.swift` (CoreGraphics). Everything else
in `Platform/Persistence` compiles here verbatim, including the whole bundle
refresh surface. `Sources/CryptoKit` re-exports swift-crypto under the
CryptoKit module name so the unmodified real sources build on Linux; on Apple
hosts the app builds against the real CryptoKit.

## What is covered

23 tests against the real sources and, for the launch-path tests, the real
shipped `data.json`, `usda_ingredient_catalog.sqlite`, and `LegacyBundles` pins:

- v21 ownership migration (columns, partial unique indexes, diagnostics table).
- Ownership-key namespaces, row-side vs payload-side canonical hash projections.
- Adoption of legacy rows (id preservation, duplicate adoption winner,
  unmatched-row diagnostics), payload application (updates, inserts,
  relationship resolution), user-edit protection, removals kept + diagnosed,
  idempotent second pass, atomic rollback on injected failure.
- Snapshot-readiness gating: `.pending` refusal before any write; the launch
  path's default `.historicalNutrition` provider admitting a ready history and
  refusing otherwise; pinned catalogs never applied as current content.
- Changed-bundle invariance: a refresh that really changes bundle-derived
  content leaves journal, daily-chart, and Health-record doubles
  bit-identical over a captured frozen snapshot (non-vacuous: the test asserts
  the refresh really changed the catalog row).
- Input-contract behavior: user data referencing a removed recipe stays
  readable (rows are never deleted), and the in-place rewrite a bundle-id
  reuse causes (`BUNDLE-INPUT-CONTRACT.md` documents the rule).

The bundle input contract a new corpus must satisfy:
`apps/ios/Platform/Persistence/Bundle/BUNDLE-INPUT-CONTRACT.md`.
