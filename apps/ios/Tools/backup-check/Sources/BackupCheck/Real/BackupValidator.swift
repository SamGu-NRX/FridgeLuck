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

    return violations
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
