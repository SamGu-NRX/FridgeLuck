import Foundation
import GRDB

/// Validates a decoded archive against the real schema before any live
/// data is touched.
///
/// Validation stages, in order:
/// 1. structural (codec: caps, versions, hashes — refuses loudly),
/// 2. semantic: every archived row set is inserted into a throwaway
///    database migrated to the same schema version, with foreign keys ON.
///    Invalid relationships, CHECK violations (bad amounts, ratings,
///    ratios), and app-level invariants (snapshot completeness, confidence
///    bounds) fail here with actionable diagnostics — the live database is
///    never opened for writes during this stage.
struct BackupValidator {
  struct Violation: Equatable, Sendable {
    let table: String
    let detail: String
  }

  /// Snapshot format version the validator accepts. Mirrors
  /// `NutritionSnapshot.currentVersion` — the snapshot owner refuses to
  /// read any other version, so restoring a different one would plant
  /// rows that look present but never load. The app-target test
  /// `BackupSnapshotVersionOwnershipTests` pins the two constants
  /// together so drift fails the hosted macOS run.
  static let supportedSnapshotVersion = 1

  // MARK: Semantic validation

  /// Inserts every archived row set into a throwaway migrated database and
  /// runs semantic checks. Returns the per-table verified column lists.
  static func validateSemantics(_ archive: BackupArchive) throws -> [String: [String]] {
    // GRDB enables foreign keys by default; the throwaway queue keeps
    // that default so invalid relationships are caught at insert time.
    let staging = try DatabaseQueue()
    var verifiedColumns: [String: [String]] = [:]

    // Migrations manage their own transactions — run them OUTSIDE any
    // wrapping write so the queue is never re-entered.
    try DatabaseMigrations.migrate(staging, upTo: nil)

    try staging.write { db in
      var violations: [Violation] = []

      // Live column lists come from the migrated throwaway schema, not
      // from a hand-maintained list: an archive whose columns drift from
      // the real schema is refused here.
      for spec in BackupSchemaCatalog.insertOrder {
        let columns = try db.columns(in: spec.name).map(\.name)
        verifiedColumns[spec.name] = columns
      }

      // Migrations may seed bundled-resource rows (e.g. dish_templates);
      // clear every catalog table so archived rows insert into a clean
      // slate, mirroring the restore engine's replace-only flow.
      for spec in BackupSchemaCatalog.insertOrder.reversed() {
        _ = try db.execute(sql: "DELETE FROM \"\(spec.name)\"")
      }

      for spec in BackupSchemaCatalog.insertOrder {
        guard let manifest = archive.tables.first(where: { $0.name == spec.name }) else {
          // Every catalog table must be present in the archive.
          violations.append(.init(table: spec.name, detail: "missing from archive"))
          continue
        }

        let columns = verifiedColumns[spec.name] ?? []
        guard Set(manifest.columns) == Set(columns), manifest.columns.count == columns.count else {
          violations.append(
            .init(
              table: spec.name,
              detail:
                "columns \(manifest.columns.sorted().joined(separator: ",")) do not match "
                + "schema \(columns.sorted().joined(separator: ","))"))
          continue
        }

        let rows = try BackupArchiveCodec.parseRows(
          rawRows: archive.rows[spec.name] ?? [], columns: manifest.columns)

        do {
          try Self.insertRows(
            db: db, table: spec.name, columns: manifest.columns, rows: rows)
        } catch {
          // Invalid relationships and CHECK violations surface here,
          // with the failing table named. Nothing is written to live data.
          violations.append(
            .init(
              table: spec.name,
              detail: "row rejected: \(Self.describe(error))"))
        }
      }

      violations.append(contentsOf: try Self.amountViolations(db))
      violations.append(contentsOf: try Self.snapshotCompletenessViolations(db))

      let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
      for fk in fkRows {
        if let table = fk[0] as? String {
          violations.append(
            .init(table: table, detail: "foreign key check failed"))
        }
      }

      if !violations.isEmpty {
        throw BackupValidationError(violations: violations)
      }
    }

    try? staging.close()
    return verifiedColumns
  }

  private static func describe(_ error: Error) -> String {
    if let dbError = error as? DatabaseError {
      return "(\(dbError.errorCode)) \(dbError.message)"
    }
    return String(describing: error)
  }

  static func insertRows(
    db: Database, table: String, columns: [String], rows: [[BackupValue?]]
  ) throws {
    guard !rows.isEmpty else { return }
    let columnList = columns.map { "\"\($0)\"" }.joined(separator: ", ")
    let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
    let sql = "INSERT INTO \"\(table)\" (\(columnList)) VALUES (\(placeholders))"
    let statement = try db.makeStatement(sql: sql)

    for row in rows {
      let arguments = row.map { value -> DatabaseValue? in
        value?.databaseValue
      }
      // Statement.arguments binding with nil → NULL.
      try statement.execute(arguments: StatementArguments(arguments.map { $0 ?? .null }))
    }
  }

  // MARK: Amount sanity (app-level invariants beyond schema CHECKs)

  static func amountViolations(_ db: Database) throws -> [Violation] {
    var violations: [Violation] = []

    func count(_ sql: String, _ table: String, _ detail: String) throws {
      let n = try Int.fetchOne(db, sql: sql) ?? 0
      if n > 0 {
        violations.append(.init(table: table, detail: "\(n) rows: \(detail)"))
      }
    }

    try count(
      "SELECT COUNT(*) FROM inventory_lots WHERE confidence_score < 0 OR confidence_score > 1",
      "inventory_lots", "confidence_score outside [0, 1]")
    try count(
      "SELECT COUNT(*) FROM inventory_lots WHERE quantity_grams < 0 OR remaining_grams < 0",
      "inventory_lots", "negative grams")
    try count(
      "SELECT COUNT(*) FROM inventory_events WHERE confidence_score < 0 OR confidence_score > 1",
      "inventory_events", "confidence_score outside [0, 1]")
    try count(
      "SELECT COUNT(*) FROM inventory_items WHERE average_confidence_score < 0 "
        + "OR average_confidence_score > 1 OR total_remaining_grams < 0",
      "inventory_items", "confidence out of range or negative remaining grams")
    try count(
      "SELECT COUNT(*) FROM cooking_history_swaps WHERE ratio <= 0",
      "cooking_history_swaps", "non-positive swap ratio")
    try count(
      "SELECT COUNT(*) FROM cooking_history WHERE portion_multiplier IS NOT NULL "
        + "AND portion_multiplier <= 0",
      "cooking_history", "non-positive portion multiplier")
    try count(
      "SELECT COUNT(*) FROM cooking_history WHERE rating IS NOT NULL AND (rating < 1 OR rating > 5)",
      "cooking_history", "rating outside 1...5")
    try count(
      "SELECT COUNT(*) FROM cooking_history_nutrition_lines WHERE swap_ratio <= 0 "
        + "OR quantity_grams < 0",
      "cooking_history_nutrition_lines", "non-positive ratio or negative grams")

    for nutrient in ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"] {
      try count(
        "SELECT COUNT(*) FROM cooking_history_nutrition_lines WHERE \(nutrient) IS NOT NULL "
          + "AND \(nutrient) < 0",
        "cooking_history_nutrition_lines", "negative \(nutrient)")
    }

    return violations
  }

  // MARK: Snapshot completeness (v20 invariant)

  /// Every cooking_history row whose recipe still exists must carry a
  /// nutrition snapshot; orphaned history (recipe gone) legitimately has
  /// none. Lines must have a dense 0-based line_index per meal.
  static func snapshotCompletenessViolations(_ db: Database) throws -> [Violation] {
    var violations: [Violation] = []

    let missingSnapshots = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history ch
        WHERE EXISTS (SELECT 1 FROM recipes r WHERE r.id = ch.recipe_id)
          AND NOT EXISTS (
            SELECT 1 FROM cooking_history_nutrition_snapshots s WHERE s.history_id = ch.id)
        """) ?? 0
    if missingSnapshots > 0 {
      violations.append(
        .init(
          table: "cooking_history_nutrition_snapshots",
          detail: "\(missingSnapshots) logged meals have no nutrition snapshot"))
    }

    let sparseLines = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM (
          SELECT history_id FROM cooking_history_nutrition_lines
          GROUP BY history_id
          HAVING MIN(line_index) != 0 OR MAX(line_index) != COUNT(*) - 1
        )
      """) ?? 0
    if sparseLines > 0 {
      violations.append(
        .init(
          table: "cooking_history_nutrition_lines",
          detail: "\(sparseLines) meals have non-dense line_index values"))
    }

    let unknownSnapshots = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history_nutrition_snapshots s
        WHERE NOT EXISTS (
          SELECT 1 FROM cooking_history ch WHERE ch.id = s.history_id)
        """) ?? 0
    if unknownSnapshots > 0 {
      violations.append(
        .init(
          table: "cooking_history_nutrition_snapshots",
          detail: "\(unknownSnapshots) snapshots point at missing cooking_history rows"))
    }

    // Snapshot format versions are owned by NutritionSnapshot, which
    // refuses to read any version other than its current one. A future
    // snapshot_version must therefore be refused at staging: restoring it
    // would plant rows the snapshot owner cannot read, poisoning reports
    // with data that looks present but never loads.
    let unsupportedSnapshots = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history_nutrition_snapshots
        WHERE snapshot_version != \(Self.supportedSnapshotVersion)
        """) ?? 0
    if unsupportedSnapshots > 0 {
      violations.append(
        .init(
          table: "cooking_history_nutrition_snapshots",
          detail:
            "\(unsupportedSnapshots) snapshots carry a snapshot_version unsupported by the snapshot owner (expected \(Self.supportedSnapshotVersion))"))
    }

    return violations
  }

  // MARK: Live schema (pinned-catalog agreement)

  /// Refusal raised when the live database's schema does not match the
  /// pinned backup catalog. Exporting such a database would mislabel it as
  /// the pinned schema version, and a replace-only restore that touched
  /// only catalog tables would silently strand every other table's data.
  struct BackupLiveSchemaError: Error, Equatable, Sendable {
    /// Live tables absent from the catalog (a later migration added one).
    let unknownTables: [String]
    /// Catalog tables missing from the live database.
    let missingTables: [String]
    /// Catalog tables whose live columns disagree with the migrated schema.
    let columnDrift: [String]
  }

  /// Tables SQLite manages internally (bookkeeping such as
  /// `sqlite_sequence`, `sqlite_stat1`). They are supported, carry no
  /// FridgeLuck user data, and never count as unknown live tables.
  static let sqliteInternalPrefix = "sqlite_"

  /// GRDB migrator bookkeeping. Created by every production database
  /// (migrations run through GRDB) but absent from migrated throwaway
  /// copies that do not use the migrator; it carries no user data.
  static let grdbBookkeepingTable = "grdb_migrations"

  /// The live database's user tables: everything in `sqlite_master`
  /// except SQLite's internal bookkeeping and GRDB's migrator bookkeeping.
  static func liveUserTables(_ db: Database) throws -> Set<String> {
    let names = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    return Set(names.filter {
      !$0.hasPrefix(sqliteInternalPrefix) && $0 != grdbBookkeepingTable
    })
  }

  /// Cheap agreement check: the live user-table set must equal the catalog
  /// exactly. Safe to run inside the replace transaction before anything
  /// is wiped.
  static func assertKnownLiveTables(_ db: Database) throws {
    let live = try liveUserTables(db)
    let catalog = Set(BackupSchemaCatalog.tables.map(\.name))
    let unknown = live.subtracting(catalog).sorted()
    let missing = catalog.subtracting(live).sorted()
    guard unknown.isEmpty, missing.isEmpty else {
      throw BackupLiveSchemaError(
        unknownTables: unknown, missingTables: missing, columnDrift: [])
    }
  }

  /// Full agreement check against the pinned schema: table-set equality
  /// plus per-table column agreement with a throwaway database migrated
  /// to the current schema. Runs before export and before the restore
  /// transaction; never inside one (it opens its own connection).
  static func validateLiveSchema(_ db: Database) throws {
    try assertKnownLiveTables(db)

    let staging = try DatabaseQueue()
    defer { try? staging.close() }
    try DatabaseMigrations.migrate(staging, upTo: nil)
    let expectedColumns: [String: [String]] = try staging.read { migrated in
      var columnsByTable: [String: [String]] = [:]
      for spec in BackupSchemaCatalog.tables {
        columnsByTable[spec.name] = try migrated.columns(in: spec.name).map(\.name).sorted()
      }
      return columnsByTable
    }

    var columnDrift: [String] = []
    for spec in BackupSchemaCatalog.tables {
      let liveColumns = try db.columns(in: spec.name).map(\.name).sorted()
      if liveColumns != (expectedColumns[spec.name] ?? []) {
        columnDrift.append(spec.name)
      }
    }
    guard columnDrift.isEmpty else {
      throw BackupLiveSchemaError(
        unknownTables: [], missingTables: [], columnDrift: columnDrift.sorted())
    }
  }
}

/// Semantic validation failure: carries the violating tables and details so
/// the UI can refuse a restore with specifics instead of a generic error.
struct BackupValidationError: Error, Sendable {
  let violations: [BackupValidator.Violation]
}

// MARK: - Preview

/// What the user is shown before consenting to a replace-only restore.
struct RestorePreview: Equatable, Sendable {
  struct TableSummary: Equatable, Sendable {
    let name: String
    let tableClass: BackupTableClass
    let rowCount: Int
  }

  let archive: BackupArchive
  let createdAt: String
  let schemaVersion: Int
  let includesPhotos: Bool
  let photoCount: Int
  let userRecordTables: [TableSummary]
  let bundledResourceTables: [TableSummary]
  let totalUserRows: Int
  let totalBundledRows: Int

  static func build(archive: BackupArchive) -> RestorePreview {
    var user: [TableSummary] = []
    var bundled: [TableSummary] = []
    for manifest in archive.tables {
      let tableClass = BackupSchemaCatalog.spec(named: manifest.name)?.class ?? .userRecords
      let summary = TableSummary(
        name: manifest.name, tableClass: tableClass, rowCount: manifest.rowCount)
      if tableClass == .userRecords {
        user.append(summary)
      } else {
        bundled.append(summary)
      }
    }
    return RestorePreview(
      archive: archive,
      createdAt: archive.createdAt,
      schemaVersion: archive.schemaVersion,
      includesPhotos: archive.includesPhotos,
      photoCount: archive.photos?.count ?? 0,
      userRecordTables: user,
      bundledResourceTables: bundled,
      totalUserRows: user.reduce(0) { $0 + $1.rowCount },
      totalBundledRows: bundled.reduce(0) { $0 + $1.rowCount })
  }
}
