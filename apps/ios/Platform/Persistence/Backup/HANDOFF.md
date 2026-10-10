# Handoff — Local backup & restore (schema v20)

## What exists

| Piece | File | Role |
|---|---|---|
| Archive codec | `BackupArchive.swift` | v1 JSON format pinned to schema v20; typed tagged cells (`i:`/`d:`/`s:`); per-table SHA-256 manifests; `BackupLimits` caps; photo-path safety; hash verification on decode. Unsupported format/schema versions and unknown tables are refused. |
| Validator | `BackupValidator.swift` | Semantic validation against a throwaway migrated database: column-shape check, constraint-level inserts (FK/CHECK/UNIQUE), amount sanity, snapshot completeness, nutrition-line density. Migration-seeded bundled rows are cleared before archive rows are inserted. Builds the user-facing `RestorePreview`. |
| Engine | `BackupRestoreEngine.swift` | `exportArchive` (all 25 catalog tables; photos optional with SHA-256 digests) and staged replace-only restore: `VACUUM INTO` safety copy → ONE transaction (wipe reverse-FK, insert FK order, staged revalidation) → publish `.fridgeLuckUserDataDidRestore` only after commit. `FileManager` is never stored (non-Sendable); each operation uses `.default` locally. |
| Settings UI | `../../Feature/Settings/SettingsBackupView.swift` | Share (export → `ShareLink`), import (`fileImporter` → stage → preview → destructive confirm → commit), error alerts. Reached via a `Backup` section in Data & Privacy (`SettingsRoute.backup`). Builds its own engine against `deps.appDatabase.dbQueue`; mirrors AppDatabase's path derivation read-only. |
| Linux checks | `../../Tools/backup-check/` | SwiftPM package; `Scripts/refresh.sh` copies the four real persistence sources into `Sources/BackupCheck/Real/`. 23 XCTests. |

## What was checked

- Linux, Swift 6.1.2 (`-Xswiftc -DSQLITE_DISABLE_SNAPSHOT`): `swift build --build-tests` clean; `swift test` — 23/23 pass (backup-check). Historical-nutrition check package: 10/10 pass.
- The macOS CI failure on the first push was exactly the stored-`FileManager` Sendable error at `BackupRestoreEngine.swift:36`; fixed by making `FileManager` operation-local. No `@unchecked Sendable`, no compiler flags weakened. Strict archive/snapshot/path validation and staged restore semantics unchanged.

## What was NOT checked

- **The iOS app target has never been built here** (no Xcode). Hosted macOS CI is the arbiter — watch the `build-and-test` check on PR #61. `SettingsBackupView.swift`, `SettingsRoute.swift`, `SettingsView.swift`, and `SettingsDataAndPrivacyView.swift` are SwiftUI changes that only compile on Apple toolchains.
- **Inherited snapshot fixture failures:** once CI compiles, macOS tests may surface snapshot-fixture failures inherited from the base branch (`obv/fl-next-historical-nutrition-r1`). Both Linux suites pass here, so any such failures are separate from this branch's changes and should be triaged on their own — not patched inside this PR.
- The Settings UI is untested by automation (no UI-test target); the restore path it drives is covered by the Linux suite.

## Decisions worth knowing

- **Replace-only restore** (format v1): every catalog table is wiped, including bundled resources the archive carries — preview distinguishes user records from bundled rows. Partial restore is deliberately out of scope.
- **Notification after commit only.** The engine is injectable on `NotificationCenter`; consumers subscribe to `.fridgeLuckUserDataDidRestore`. Consumer wiring (e.g. refreshing in-memory caches) is intentionally NOT in this branch — nothing outside tests currently observes the notification.
- **No shared lifecycle/registrar edits:** the Settings model duplicates AppDatabase's path derivation with a comment rather than adding an accessor. If AppDatabase ever moves the database file, `SettingsBackupModel.init` must follow.
- **Validation runs against a throwaway migrated DB**, not the live one — so a corrupt archive can never half-apply.

## Open questions

- Should exported files get a custom UTI/extension (`.fridgeluck.json`) instead of plain `.json`? The importer currently accepts `[.json]`.
- Restore keeps the safety copy on failure for forensics; nothing surfaces it to the user yet.
