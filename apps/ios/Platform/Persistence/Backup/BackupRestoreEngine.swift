import Foundation
import GRDB
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

/// Exports FridgeLuck user data into a versioned archive, and restores it
/// through a previewed, transactional, replace-only flow.
///
/// The engine never touches `AppDatabase`'s lifecycle or file handling: it
/// receives the app's existing `DatabaseWriter` (the same shared
/// `DatabaseQueue` every repository uses) and works through ordinary
/// transactions on that writer. There is no file swapping, no reopening,
/// no replacement of the database the app already holds open.
///
/// Restore is replace-only by design (format version 1): every catalog
/// table is wiped and refilled from the archive inside ONE transaction,
/// followed by in-transaction staged validation (row-by-row counts and
/// canonical hashes). The original database content is retained until
/// staged validation completes: a safety copy is made first, and any
/// failure — validation, disk, interruption — rolls the transaction back
/// and keeps the safety copy for forensics.
struct BackupRestoreEngine: Sendable {
  /// The app's shared writer. Never replaced, never reopened.
  let writer: any DatabaseWriter
  /// Path of the live SQLite file, used only to make the pre-restore
  /// safety copy.
  let databasePath: String
  /// Documents directory holding `MealPhotos/`, when photos can be
  /// exported/restored. Nil in portable (Linux) test environments.
  let documentsDirectory: URL?
  /// Directory that holds safety copies between staging and completion.
  let stagingRoot: URL
  let fileManager: FileManager
  let center: NotificationCenter

  init(
    writer: any DatabaseWriter,
    databasePath: String,
    documentsDirectory: URL? = nil,
    stagingRoot: URL? = nil,
    fileManager: FileManager = .default,
    center: NotificationCenter = .default
  ) {
    self.writer = writer
    self.databasePath = databasePath
    self.documentsDirectory = documentsDirectory
    if let stagingRoot {
      self.stagingRoot = stagingRoot
    } else {
      self.stagingRoot = URL(
        fileURLWithPath: databasePath, isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("backup-staging", isDirectory: true)
    }
    self.fileManager = fileManager
    self.center = center
  }

  // MARK: - Errors

  enum RestoreError: Error, Equatable {
    case safetyCopyFailed(String)
    case archiveChangedSinceStaging
  }

  // MARK: - Export

  /// Exports every catalog table at the current schema. Photos are OFF by
  /// default; when enabled, files under `MealPhotos/` referenced by
  /// `cooking_history.image_path` are embedded with SHA-256 hashes.
  /// Missing photo files are skipped and reported, never fatal.
  func exportArchive(
    includesPhotos: Bool = false, appVersion: String? = nil
  ) async throws -> Data {
    var archive = try await writer.read { db in
      var tables: [BackupTableManifest] = []
      var rowsByName: [String: [[String?]]] = [:]

      for spec in BackupSchemaCatalog.tables {
        let fetched = try Row.fetchAll(db, sql: "SELECT * FROM \"\(spec.name)\"")
        let columns =
          try fetched.first.map { Array($0.columnNames) }
          ?? db.columns(in: spec.name).map(\.name)
        let rows: [[BackupValue?]] = fetched.map { row in
          row.databaseValues.map(Self.backupValue(from:))
        }
        let hash = BackupArchiveCodec.canonicalHash(
          table: spec.name, columns: columns,
          primaryKey: spec.primaryKey, rows: rows)
        tables.append(
          BackupTableManifest(
            name: spec.name,
            tableVersion: spec.tableVersion,
            tableClass: spec.class.rawValue,
            columns: columns,
            rowCount: rows.count,
            rowsSHA256: hash))
        rowsByName[spec.name] = rows.map { row in
          row.map { BackupArchiveCodec.cellString($0) }
        }
      }

      let dateFormatter = ISO8601DateFormatter()
      dateFormatter.formatOptions = [.withInternetDateTime]

      return BackupArchive(
        format: BackupSchemaCatalog.formatName,
        formatVersion: BackupSchemaCatalog.formatVersion,
        createdAt: dateFormatter.string(from: Date()),
        schemaVersion: BackupSchemaCatalog.currentSchemaVersion,
        includesPhotos: includesPhotos,
        appVersion: appVersion,
        tables: tables,
        rows: rowsByName,
        photos: nil)
    }

    if includesPhotos {
      archive.photos = try collectPhotos(referencedIn: archive)
    }
    return try BackupArchiveCodec.encode(archive)
  }

  private static func backupValue(from dbValue: DatabaseValue) -> BackupValue? {
    switch dbValue.storage {
    case .null:
      return nil
    case .int64(let v):
      return .int(v)
    case .double(let v):
      return .double(v)
    case .string(let s):
      return .text(s)
    case .blob:
      // No BLOB columns exist at schema v20; an unexpected blob is a
      // coding error and refuses the export rather than losing data.
      return .text("__blob_unsupported__")
    }
  }

  private func collectPhotos(referencedIn archive: BackupArchive) throws -> [BackupPhotoEntry] {
    guard let documentsDirectory else { return [] }
    guard let historyManifest = archive.tables.first(where: {
      $0.name == "cooking_history"
    }) else { return [] }
    let imageColumn = historyManifest.columns.firstIndex(of: "image_path")
    let paths = (archive.rows["cooking_history"] ?? []).compactMap { row -> String? in
      guard let index = imageColumn, row.indices.contains(index) else { return nil }
      // Row cells are tagged ("s:MealPhotos/…"); recover the plain path.
      guard
        let parsed = try? BackupValue.parse(row[index]),
        case .text(let path) = parsed
      else { return nil }
      return path
    }

    var entries: [BackupPhotoEntry] = []
    var seen = Set<String>()
    for taggedPath in paths {
      // The real app stores plain "MealPhotos/UUID.jpg" paths; anything
      // else (nil, remote URLs) is skipped by the path check.
      let relativePath = taggedPath ?? ""
      guard BackupArchiveCodec.isAcceptablePhotoPath(relativePath), !seen.contains(relativePath)
      else { continue }
      seen.insert(relativePath)

      let url = documentsDirectory.appendingPathComponent(relativePath)
      guard let data = try? Data(contentsOf: url) else { continue }
      let digest = SHA256.hash(data: data)
      entries.append(
        BackupPhotoEntry(
          relativePath: relativePath,
          sha256: digest.map { String(format: "%02x", $0) }.joined(),
          base64Data: data.base64EncodedString()))
    }
    return entries
  }

  // MARK: - Staged restore

  /// Stage 1 — parse, structurally decode, and semantically validate the
  /// archive against a throwaway migrated database. The live database is
  /// NOT modified by this call. Returns what the user previews.
  func stageRestore(archiveData: Data) async throws -> RestorePreview {
    let archive = try BackupArchiveCodec.decode(archiveData)
    _ = try BackupValidator.validateSemantics(archive)
    return RestorePreview.build(archive: archive)
  }

  /// Stage 2 — replace all data, transactionally.
  ///
  /// Order of operations:
  /// 1. safety copy of the live database (failure aborts, live data
  ///    untouched),
  /// 2. ONE transaction: wipe every catalog table (reverse FK order),
  ///    insert archived rows (FK order), then staged validation inside the
  ///    same transaction — per-table row-by-row counts and canonical
  ///    hashes, snapshot completeness, foreign-key check. Any failure
  ///    throws and rolls everything back.
  /// 3. only after the commit: safety copy retired, then the
  ///    `fridgeLuckUserDataDidRestore` notification is published.
  func commitRestore(_ preview: RestorePreview) async throws -> RestoreReport {
    let archive = preview.archive

    try Task.checkCancellation()
    let safetyDirectory = try makeSafetyCopy()

    do {
      let report = try await replaceAllData(with: archive)
      // Staged validation completed and the transaction committed: the
      // original database content is no longer needed.
      try? fileManager.removeItem(at: safetyDirectory)
      restorePhotoFiles(from: archive)
      recoverOrphanedSafetyCopies()
      // Published only after committed replacement.
      center.post(name: .fridgeLuckUserDataDidRestore, object: nil)
      return report
    } catch {
      // Transaction rolled back: live data is intact. The safety copy is
      // retained on purpose — the caller can inspect what the pre-restore
      // database looked like.
      throw error
    }
  }

  /// Runs the wipe + insert + validate cycle in one transaction on the
  /// existing writer.
  private func replaceAllData(with archive: BackupArchive) async throws -> RestoreReport {
    try await writer.write { db in
      // Wipe, reverse topological order so foreign keys never dangle
      // mid-flight.
      for spec in BackupSchemaCatalog.deleteOrder {
        try db.execute(sql: "DELETE FROM \"\(spec.name)\"")
      }

      // Insert, topological order, canonical PK order for determinism.
      for spec in BackupSchemaCatalog.insertOrder {
        guard let manifest = archive.tables.first(where: { $0.name == spec.name }) else {
          throw BackupArchiveError.malformedArchive(
            "archive lost table \(spec.name) between staging and commit")
        }
        let rows = try BackupArchiveCodec.parseRows(
          rawRows: archive.rows[spec.name] ?? [], columns: manifest.columns)
        try BackupValidator.insertRows(
          db: db, table: spec.name, columns: manifest.columns, rows: rows)
      }

      // Staged validation, still inside the transaction: if anything
      // disagrees with the archive, this throws, the transaction rolls
      // back, and the original data survives untouched.
      return try Self.stagedValidation(db: db, archive: archive)
    }
  }

  /// Row-by-row comparison of the staged database state against the
  /// archive manifest: counts AND canonical content hashes per table,
  /// plus the v20 snapshot-completeness invariant and a full foreign-key
  /// check. Runs inside the replace transaction.
  static func stagedValidation(
    db: Database, archive: BackupArchive
  ) throws -> RestoreReport {
    var tableCounts: [RestoreReport.TableCount] = []

    for spec in BackupSchemaCatalog.insertOrder {
      guard let manifest = archive.tables.first(where: { $0.name == spec.name }) else {
        throw BackupArchiveError.malformedArchive(
          "archive lost table \(spec.name) between staging and commit")
      }

      let liveRows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(spec.name)\"")
      let liveColumns =
        try liveRows.first.map { Array($0.columnNames) }
        ?? db.columns(in: spec.name).map(\.name)
      let values: [[BackupValue?]] = liveRows.map { row in
        row.databaseValues.map { value in
          switch value.storage {
          case .null: return nil
          case .int64(let v): return .int(v)
          case .double(let v): return .double(v)
          case .string(let s): return .text(s)
          case .blob: return nil
          }
        }
      }

      let liveHash = BackupArchiveCodec.canonicalHash(
        table: spec.name, columns: liveColumns,
        primaryKey: spec.primaryKey, rows: values)

      guard values.count == manifest.rowCount else {
        throw validationFailure(
          table: spec.name,
          detail: "row count \(values.count) != archived \(manifest.rowCount)")
      }
      guard liveHash == manifest.rowsSHA256 else {
        throw validationFailure(
          table: spec.name, detail: "canonical hash mismatch after restore")
      }

      tableCounts.append(
        RestoreReport.TableCount(
          name: spec.name,
          tableClass: spec.class.rawValue,
          archivedRows: manifest.rowCount,
          restoredRows: values.count,
          hashMatch: true))
    }

    let snapshotViolations = try BackupValidator.snapshotCompletenessViolations(db)
    if !snapshotViolations.isEmpty {
      throw validationFailure(
        table: snapshotViolations[0].table, detail: snapshotViolations[0].detail)
    }

    let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
    if let fk = fkRows.first, let table = fk[0] as? String {
      throw validationFailure(table: table, detail: "foreign key check failed")
    }

    let userRows = tableCounts
      .filter { $0.tableClass == BackupTableClass.userRecords.rawValue }
      .reduce(0) { $0 + $1.restoredRows }
    let bundledRows = tableCounts
      .filter { $0.tableClass == BackupTableClass.bundledResources.rawValue }
      .reduce(0) { $0 + $1.restoredRows }

    return RestoreReport(
      tables: tableCounts, restoredUserRows: userRows, restoredBundledRows: bundledRows,
      photosRestored: 0, photoWarnings: [])
  }

  /// Local error shaped like `BackupValidator.Violation`-backed failure:
  /// thrown inside staged validation, it rolls the transaction back.
  private static func validationFailure(table: String, detail: String) -> Error {
    BackupValidationError(violations: [.init(table: table, detail: detail)])
  }

  // MARK: - Safety copy

  /// Safety copies of the live database, retained until staged validation
  /// completes. A crash between copy and commit leaves a directory here;
  /// `recoverOrphanedSafetyCopies` retires them after the next successful
  /// restore.
  func pendingSafetyCopies() -> [URL] {
    let contents = (try? fileManager.contentsOfDirectory(
      at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.lastPathComponent.hasPrefix("safety-") }
  }

  /// Copies the live database into a fresh staging directory using
  /// SQLite's own `VACUUM INTO`, which produces a consistent snapshot of
  /// the database including its WAL content, even while the app keeps
  /// using the original. Runs without a surrounding transaction because
  /// VACUUM refuses to run inside one.
  private func makeSafetyCopy() throws -> URL {
    do {
      try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
      let directory = stagingRoot.appendingPathComponent(
        "safety-\(UUID().uuidString)", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = directory.appendingPathComponent("original.sqlite").path
      if fileManager.fileExists(atPath: target) {
        try fileManager.removeItem(atPath: target)
      }
      try writer.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [target])
      }
      guard fileManager.fileExists(atPath: target) else {
        throw RestoreError.safetyCopyFailed("VACUUM INTO produced no file")
      }
      return directory
    } catch let error as RestoreError {
      throw error
    } catch {
      throw RestoreError.safetyCopyFailed(String(describing: error))
    }
  }

  /// Retires safety copies orphaned by an earlier interrupted restore. Safe
  /// because restores are transactional: after any successful commit, the
  /// live database is complete and consistent on its own.
  private func recoverOrphanedSafetyCopies() {
    for url in pendingSafetyCopies() {
      try? fileManager.removeItem(at: url)
    }
  }

  // MARK: - Photos

  /// Writes archived photo files into the documents directory AFTER the
  /// database commit. Photo failures never roll back the committed
  /// database; they are reported as warnings instead.
  private func restorePhotoFiles(from archive: BackupArchive) {
    guard let documentsDirectory, archive.includesPhotos else { return }
    for photo in archive.photos ?? [] {
      guard BackupArchiveCodec.isAcceptablePhotoPath(photo.relativePath),
        let data = Data(base64Encoded: photo.base64Data)
      else {
        continue
      }
      let url = documentsDirectory.appendingPathComponent(photo.relativePath)
      do {
        try fileManager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        continue
      }
    }
  }
}

// MARK: - Report

/// Evidence of the row-by-row comparison between the archive and the
/// staged database, collected inside the restore transaction.
struct RestoreReport: Equatable, Sendable {
  struct TableCount: Equatable, Sendable {
    let name: String
    let tableClass: String
    let archivedRows: Int
    let restoredRows: Int
    let hashMatch: Bool
  }

  let tables: [TableCount]
  let restoredUserRows: Int
  let restoredBundledRows: Int
  let photosRestored: Int
  let photoWarnings: [String]
}

