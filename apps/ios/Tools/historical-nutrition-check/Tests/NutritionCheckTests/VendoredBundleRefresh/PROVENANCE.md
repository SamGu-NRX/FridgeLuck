# VendoredBundleRefresh — provenance

**VENDORED TEST FIXTURES — NOT PRODUCTION CODE. Delete this directory when PR #44
merges into this branch's base.**

## Source

Vendored from **PR #44**, branch `obv/fl-next-bundled-refresh`, head
`7dc2b219204c6f272bf661fe031cc76fa1d38732` (fetched read-only on 2026-10-11;
checked again before commit — see the PR body for the head used at commit time).
These files exercise the changed-bundle refresh flow against the real refresh
owner instead of a hand-rolled stub. Nothing in this directory is referenced by
app targets; it exists only under `Tests/NutritionCheckTests/`.

## Files

| Vendored file | Original path on obv/fl-next-bundled-refresh |
| --- | --- |
| `AppDatabase.swift` | `apps/ios/Platform/Persistence/Database/AppDatabase.swift` |
| `BundleOwnership.swift` | `apps/ios/Platform/Persistence/Bundle/BundleOwnership.swift` |
| `BundledDataLoader.swift` | `apps/ios/Platform/Persistence/Bundle/BundledDataLoader.swift` |
| `BundledDataLoaderRecipeHydration.swift` | `apps/ios/Platform/Persistence/Bundle/BundledDataLoaderRecipeHydration.swift` |
| `BundledDataLoaderUSDACatalog.swift` | `apps/ios/Platform/Persistence/Bundle/BundledDataLoaderUSDACatalog.swift` |
| `BundledDataRefresher.swift` | `apps/ios/Platform/Persistence/Bundle/BundledDataRefresher.swift` |
| `BundledDataValidator.swift` | `apps/ios/Platform/Persistence/Bundle/BundledDataValidator.swift` |
| `LegacyBundlePins.swift` | `apps/ios/Platform/Persistence/Bundle/LegacyBundlePins.swift` |

Only `VendoredBundleOwnershipMigration.swift` is written here, not vendored: it
extracts the `v21_bundle_ownership` migration body verbatim from
`apps/ios/Platform/Persistence/Database/Migrations.swift` on the same head, so
the Flow E fixture can apply the refresh owner's schema after this branch's
`v20_historical_nutrition_snapshots` (the package migrator does not carry PR
#44's stream yet).

## Modifications (mechanical, behaviour-preserving)

1. Conditional imports: `#if canImport(CryptoKit)` / `import Crypto` (swift-crypto)
   where the originals imported CryptoKit unconditionally — Linux has no CryptoKit.
2. `@testable import NutritionCheck` where a vendored file references this
   package's types (`NutritionSnapshotService`, `Recipe`/`Ingredient`,
   `DatabaseMigrations`), each marked with a `// VENDORED-REPAIR` comment.
3. Added `swift-crypto` to `Package.swift` as a test-only dependency for the
   `Crypto` module on Linux.
4. No logic edits: after filtering the shim lines above, each vendored file is
   byte-identical to the source head (verified by diff before committing;
   `BundledDataValidator` needed no shim at all).

## Known-good state

Under Linux SwiftPM (Swift 6.4, SQLite 3.46.1) this vendored surface compiles
and the Flow E integration passes. The compile errors reported for PR #44's
head elsewhere did not reproduce for this file subset; the full app target is
NOT exercised here — native/iOS build status remains UNVERIFIED-NATIVE and is
tracked by PR #44's own task, not this one.

## Refresh protocol

If PR #44's head moves, re-fetch `obv/fl-next-bundled-refresh`, diff each file
against the head above, and either update the vendored copy or record the drift
here before re-running Flow E. Never edit the vendored logic to make a test
pass — that would falsify the integration evidence.
