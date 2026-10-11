# Handoff — Local backup & restore (schema v20)

## What exists

| Piece | File | Role |
|---|---|---|
| Archive codec | `BackupArchive.swift` | v1 JSON format pinned to schema v20; typed tagged cells (`i:`/`d:`/`s:`); per-table SHA-256 manifests; `BackupLimits` caps; photo-path safety; hash verification on decode. Unsupported format/schema versions and unknown tables are refused. |
| Validator | `BackupValidator.swift` | Semantic validation against a throwaway migrated database: column-shape check, constraint-level inserts (FK/CHECK/UNIQUE), amount sanity, snapshot completeness, nutrition-line density. Migration-seeded bundled rows are cleared before archive rows are inserted. Also enforces **live pinned-schema agreement** (`validateLiveSchema` / `assertKnownLiveTables`): the live database's user tables and per-table columns must exactly match the pinned v20 catalog, refusing unknown later tables at export and before and inside the restore transaction; SQLite `sqlite_*` bookkeeping and GRDB's `grdb_migrations` are exempt. The snapshot-version gate uses `supportedSnapshotVersion`, a documented mirror of `NutritionSnapshot.currentVersion` pinned together by `Tests/BackupSnapshotVersionOwnershipTests.swift` (portable package cannot compile the snapshot service). Builds the user-facing `RestorePreview`. |
| Engine | `BackupRestoreEngine.swift` | `exportArchive` (validates live schema first; all 25 catalog tables; photos optional with SHA-256 digests) and staged replace-only restore: `VACUUM INTO` safety copy → live-schema agreement → ONE transaction (re-check table set, wipe reverse-FK, insert FK order, staged revalidation) → publish `.fridgeLuckUserDataDidRestore` only after commit. Cancellation checkpoints sit only at points that still roll back cleanly (before work, and inside the replace transaction before the wipe); there is deliberately no check after commit. `FileManager` is never stored (non-Sendable); each operation uses `.default` locally. |
| Settings UI | `../../Feature/Settings/SettingsBackupView.swift` | Share (export → `ShareLink`), import (`fileImporter` → stage → preview → destructive confirm → commit), error alerts. Reached via a "Backup & Restore" row in the Settings hub's More section (`SettingsRoute.backup`); the reserved Data & Privacy view is untouched. Builds its own engine against `deps.appDatabase.dbQueue`; mirrors AppDatabase's path derivation read-only. |
| Linux checks | `../../Tools/backup-check/` | SwiftPM package; `Scripts/refresh.sh` copies the four real persistence sources into `Sources/BackupCheck/Real/`. 29 XCTests. |

## What was checked

- Linux, Swift 6.1.2 (`-Xswiftc -DSQLITE_DISABLE_SNAPSHOT`): `swift build --build-tests` clean; `swift test` — 29/29 pass (backup-check), including the frozen-notification, snapshot-version-ownership, live-schema (unknown table refusal + internal-bookkeeping pass-through), and cancellation-rollback tests. Historical-nutrition check package: 10/10 pass.
- The macOS CI failure on the first push was exactly the stored-`FileManager` Sendable error at `BackupRestoreEngine.swift:36`; fixed by making `FileManager` operation-local. No `@unchecked Sendable`, no compiler flags weakened. Strict archive/snapshot/path validation and staged restore semantics unchanged.

## What was NOT checked

- **The iOS app target has never been built here** (no Xcode). Hosted macOS CI is the arbiter — watch the `build-and-test` check on PR #61. `SettingsBackupView.swift`, `SettingsRoute.swift`, `SettingsView.swift`, and `SettingsDataAndPrivacyView.swift` are SwiftUI changes that only compile on Apple toolchains.
- **Inherited snapshot fixture failures:** once CI compiles, macOS tests may surface snapshot-fixture failures inherited from the base branch (`obv/fl-next-historical-nutrition-r1`). Both Linux suites pass here, so any such failures are separate from this branch's changes and should be triaged on their own — not patched inside this PR.
- The Settings UI is untested by automation (no UI-test target); the restore path it drives is covered by the Linux suite.

## Decisions worth knowing

- **Replace-only restore** (format v1): every catalog table is wiped, including bundled resources the archive carries — preview distinguishes user records from bundled rows. Partial restore is deliberately out of scope.
- **Notification after commit only, frozen raw name.** The engine is injectable on `NotificationCenter`; consumers subscribe to `.fridgeLuckUserDataDidRestore`. The raw name `"FridgeLuckUserDataDidRestore"` is a frozen interface: an observer registered with the literal string keeps working even if the constant symbol is refactored (covered by a portable test). Consumer wiring (e.g. refreshing in-memory caches) is intentionally NOT in this branch — nothing outside tests currently observes the notification.
- **Snapshot versions are owned by `NutritionSnapshot`,** which refuses to read any version other than its current one. The validator therefore refuses to restore snapshots of any other version (`supportedSnapshotVersion`), because restoring unreadable rows would poison reports with data that looks present but never loads. The constant is mirrored, not shared, only because the portable package cannot compile the snapshot service; the app-target test pins them together.
- **Live schema must agree with the pinned catalog** before export and before and inside the restore transaction. An unknown later table must refuse rather than be silently omitted from a supposedly complete archive or stranded outside a replace-only restore.
- **No shared lifecycle/registrar edits:** the Settings model duplicates AppDatabase's path derivation with a comment rather than adding an accessor. If AppDatabase ever moves the database file, `SettingsBackupModel.init` must follow.
- **Validation runs against a throwaway migrated DB**, not the live one — so a corrupt archive can never half-apply.

## Open questions

- Should exported files get a custom UTI/extension (`.fridgeluck.json`) instead of plain `.json`? The importer currently accepts `[.json]`.
- Restore keeps the safety copy on failure for forensics; nothing surfaces it to the user yet.
