# meal-corrections-check

Offline check harness for the meal-correction feature stream. It compiles the app's
real, portable domain + persistence sources against the same GRDB pin the app uses
and runs them on any host with a Swift toolchain — no Xcode required.

```bash
./run.sh          # bootstrap + swift test (adds -DSQLITE_DISABLE_SNAPSHOT on Linux)
```

## How it works

- `bootstrap.sh` recreates `Sources/FridgeLuck/*` as **relative symlinks into the real
  app sources** (`../../../../Domain/...`). SwiftPM only compiles sources under the
  package root, so the harness reaches the repo's files through these links instead of
  stale copies. Everything the tests exercise is the real code, not a snapshot.
- `Sources/FridgeLuck/HarnessShims.swift` is the only non-symlink source: harness-only
  stand-ins for UI-coupled symbols (currently the `inventoryDidChange` notification name,
  whose app definition imports UIKit). The raw value matches the app's.
- Included sources are deliberately the portable subset: domain models + ports,
  migrations, repositories, and the plan/log/nutrition/personalization services. SwiftUI,
  UIKit, HealthKit and `os`-dependent files (views, AppleHealthService, the sync
  coordinator before its logging refactor) cannot join this package and are checked by
  the repo's hosted macOS CI instead.

## Suite

`Tests/MealPlanAgreementTests` — the accepted-plan agreement checks (display = preview =
persisted deduction), shortages, swap resolution and re-identification, fractional grams,
identity stability across rebuilds/rescales, dedup of repeated log callbacks, and the
rejections (plan/recipe mismatch, invalid grams, unknown recipe) writing nothing.
