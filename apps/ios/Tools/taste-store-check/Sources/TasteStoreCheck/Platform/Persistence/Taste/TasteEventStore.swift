import Foundation
import GRDB

import FLFeatureLogic

/// On-device store for the taste event log (docs/spec/taste/SPEC.md §5): events,
/// exposures, and profile-statement state. Nothing here leaves the device.
///
/// The persisted event and exposure models are the public contract types
/// (`FLFeatureLogic.TasteEvent` / `TasteExposure`), so what this store writes and loads is
/// exactly what `TasteResidualEngine` replays; `TasteEventRecord` /
/// `TasteExposureRecord` carry the store-only fields (cook-transaction linkage, session
/// and context columns) around them.
///
/// - Appends are idempotent by stable event id: replaying an id is a no-op, reported by
///   the append API returning `false`.
/// - Events sort by `(at, id)` on the way out, matching the replay order the spec pins.
/// - Every method is atomic on its own; pass an open `Database` (`in:` variants) to join
///   a caller's transaction, which is how a meal log and its taste events commit or roll
///   back together.
final class TasteEventStore: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// The recipe source component of the store's (source, id) event identity. A nil
  /// contract source is fine for writers (a row written with a NULL source has no
  /// identity to key on), but query entry points key on it and must fail loudly — they
  /// raise `TasteStoreError.unresolvableRecipeIdentity` instead of binding NULL in SQL,
  /// where `recipe_source = NULL` can never match.
  private static func requireRecipeSource(_ recipe: TasteRecipeRef) throws -> String {
    guard let source = recipe.source else {
      throw TasteStoreError.unresolvableRecipeIdentity(id: recipe.id, revision: recipe.revision)
    }
    return source
  }

  // MARK: - Events

  /// Appends one event in its own transaction. Returns `true` when the event was
  /// inserted, `false` when an event with the same id is already stored (replay no-op).
  @discardableResult
  func append(_ event: TasteEventRecord) throws -> Bool {
    try db.write { db in
      try append(event, in: db)
    }
  }

  /// Appends one event inside the caller's transaction. Returns `true` when inserted,
  /// `false` when the id already exists (replay no-op). Throwing rolls the caller's
  /// transaction back with it.
  @discardableResult
  func append(_ event: TasteEventRecord, in db: Database) throws -> Bool {
    // Canonical payload bytes: the typed payload re-encoded with sorted keys, so a
    // replayed event re-encodes byte-identically.
    let payloadData = try TasteEventPayloadJSON.encode(event.payload)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO taste_events
          (id, at, kind, eater, recipe_source, recipe_id, recipe_revision,
           ingredient_id, surface, cook_event_id, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        event.id,
        event.at,
        event.kind.rawValue,
        event.event.eater,
        event.event.recipe?.source,
        event.event.recipe?.id,
        event.event.recipe?.revision,
        event.ingredientId,
        event.event.surface,
        event.cookEventId,
        String(decoding: payloadData, as: UTF8.self),
      ])
    return db.changesCount > 0
  }

  /// All events for one recipe ref, oldest first. Matches on source and id.
  func events(recipe: TasteRecipeRef) throws -> [TasteEventRecord] {
    let source = try Self.requireRecipeSource(recipe)
    return try db.read { db in
      try events(
        in: db,
        where: "recipe_source = ? AND recipe_id = ?",
        arguments: [source, recipe.id])
    }
  }

  /// All events for one ingredient id, oldest first.
  func events(ingredientId: Int64) throws -> [TasteEventRecord] {
    try db.read { db in
      try events(in: db, where: "ingredient_id = ?", arguments: [ingredientId])
    }
  }

  /// Events in a time window; bounds are inclusive and nil bounds are open.
  func events(from start: Date? = nil, to end: Date? = nil) throws -> [TasteEventRecord] {
    try db.read { db in
      var clauses: [String] = []
      var arguments: [DatabaseValueConvertible] = []
      if let start {
        clauses.append("at >= ?")
        arguments.append(start)
      }
      if let end {
        clauses.append("at <= ?")
        arguments.append(end)
      }
      let whereSQL = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")
      return try events(in: db, where: whereSQL, arguments: StatementArguments(arguments))
    }
  }

  /// Every stored event, in replay order `(at, id)`.
  func allEvents() throws -> [TasteEventRecord] {
    try events(from: nil, to: nil)
  }

  /// Whether an event with this id is stored (the cheap idempotency probe).
  func containsEvent(id: String) throws -> Bool {
    try db.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM taste_events WHERE id = ?)",
        arguments: [id]) ?? false
    }
  }

  func eventCount() throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taste_events") ?? 0
    }
  }

  /// The id of the cook transaction of the most recent `recipe_cooked` event for a
  /// recipe, used to link a later rating into the cook's transaction window (SPEC §2.3).
  func latestCookEventId(for recipe: TasteRecipeRef, in db: Database) throws -> String? {
    let source = try Self.requireRecipeSource(recipe)
    return try String.fetchOne(
      db,
      sql: """
        SELECT cook_event_id FROM taste_events
        WHERE kind = ? AND recipe_source = ? AND recipe_id = ? AND cook_event_id IS NOT NULL
        ORDER BY at DESC, id DESC
        LIMIT 1
        """,
      arguments: [
        TasteEventKind.recipeCooked.rawValue, source, recipe.id,
      ])
  }

  private func events(
    in db: Database,
    where whereSQL: String,
    arguments: StatementArguments
  ) throws -> [TasteEventRecord] {
    try Row.fetchAll(
      db,
      sql: "SELECT * FROM taste_events WHERE \(whereSQL) ORDER BY at, id",
      arguments: arguments
    )
    .map { try Self.record(from: $0) }
  }

  private static func record(from row: Row) throws -> TasteEventRecord {
    let at: Date = row["at"]
    let recipeSource: String? = row["recipe_source"]
    let recipeID: String? = row["recipe_id"]
    let recipeRevision: Int? = row["recipe_revision"]
    var recipe: TasteRecipeRef?
    if let recipeSource, let recipeID, let recipeRevision {
      guard let source = TasteRecipeSource(rawValue: recipeSource) else {
        throw TasteStoreError.unknownRecipeSource(recipeSource)
      }
      recipe = TasteRecipeRef(id: recipeID, revision: recipeRevision, source: source.rawValue)
    }
    let ingredientId: Int64? = row["ingredient_id"]
    let payloadString: String = row["payload"]
    let payload = try JSONDecoder().decode(
      [String: TasteJSONValue].self, from: Data(payloadString.utf8))
    let event = TasteEvent(
      id: row["id"],
      at: TasteTimestamp.string(from: at),
      kind: row["kind"],
      eater: row["eater"],
      recipe: recipe,
      ingredient: ingredientId.map { TasteJSONValue.number(Double($0)) },
      surface: row["surface"],
      payload: payload)
    return try TasteEventRecord(
      event: event, at: at, cookEventId: row["cook_event_id"])
  }

  // MARK: - Exposures

  /// Stores one exposure render. Idempotent by exposure id: re-logging the same render
  /// is a no-op.
  func logExposure(_ exposure: TasteExposureRecord) throws {
    try db.write { db in
      try logExposure(exposure, in: db)
    }
  }

  /// Stores one exposure inside the caller's transaction.
  func logExposure(_ exposure: TasteExposureRecord, in db: Database) throws {
    let encoder = TasteEventPayloadJSON.makeEncoder()
    let slateData = try encoder.encode(exposure.exposure.slate)
    let feasibleData = try encoder.encode(exposure.exposure.feasible)
    let contextData = try encoder.encode(exposure.context)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO taste_exposures
          (id, at, surface, eater, session_id, slate, feasible, context)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        exposure.id,
        exposure.at,
        exposure.exposure.surface,
        exposure.eater,
        exposure.sessionId,
        String(decoding: slateData, as: UTF8.self),
        String(decoding: feasibleData, as: UTF8.self),
        String(decoding: contextData, as: UTF8.self),
      ])
  }

  func exposure(id: String) throws -> TasteExposureRecord? {
    try db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM taste_exposures WHERE id = ?",
        arguments: [id])
      else { return nil }
      return try Self.exposure(from: row)
    }
  }

  func allExposures() throws -> [TasteExposureRecord] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM taste_exposures ORDER BY at, id")
        .map { try Self.exposure(from: $0) }
    }
  }

  func exposureCount() throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taste_exposures") ?? 0
    }
  }

  private static func exposure(from row: Row) throws -> TasteExposureRecord {
    let decoder = JSONDecoder()
    let slateString: String = row["slate"]
    let feasibleString: String = row["feasible"]
    let contextString: String = row["context"]
    guard
      let slate = try? decoder.decode([TasteSlateItem].self, from: Data(slateString.utf8)),
      let feasible = try? decoder.decode([TasteJSONValue].self, from: Data(feasibleString.utf8)),
      let context = try? decoder.decode(TasteExposureContext?.self, from: Data(contextString.utf8))
    else {
      throw TasteStoreError.malformedExposureJSON(row["id"])
    }
    let at: Date = row["at"]
    let exposure = TasteExposure(
      id: row["id"],
      at: TasteTimestamp.string(from: at),
      surface: row["surface"],
      slate: slate,
      feasible: feasible)
    return TasteExposureRecord(
      exposure: exposure, at: at, eater: row["eater"], sessionId: row["session_id"],
      context: context)
  }

  // MARK: - Profile statements

  /// Writes statement state, updating in place when the id already exists. The taste
  /// profile branch owns statement computation; this is its storage.
  func upsertStatement(_ statement: TasteProfileStatement) throws {
    try db.write { db in
      try upsertStatement(statement, in: db)
    }
  }

  func upsertStatement(_ statement: TasteProfileStatement, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO taste_statements
          (id, layer, feature_kind, feature_key, template_id, numerator, denominator,
           state, muted_until, pinned_value, last_evidence_at, created_at, updated_at, text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          layer = excluded.layer,
          feature_kind = excluded.feature_kind,
          feature_key = excluded.feature_key,
          template_id = excluded.template_id,
          numerator = excluded.numerator,
          denominator = excluded.denominator,
          state = excluded.state,
          muted_until = excluded.muted_until,
          pinned_value = excluded.pinned_value,
          last_evidence_at = excluded.last_evidence_at,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at,
          text = excluded.text
        """,
      arguments: [
        statement.id,
        statement.layer.rawValue,
        statement.featureKind?.rawValue,
        statement.featureKey,
        statement.templateId,
        statement.numerator,
        statement.denominator,
        statement.state.rawValue,
        statement.mutedUntil,
        statement.pinnedValue,
        statement.lastEvidenceAt,
        statement.createdAt,
        statement.updatedAt,
        statement.text,
      ])
  }

  func statement(id: String) throws -> TasteProfileStatement? {
    try db.read { db in
      guard let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM taste_statements WHERE id = ?",
        arguments: [id])
      else { return nil }
      return try Self.statement(from: row)
    }
  }

  /// Statements in one layer, or every layer when `layer` is nil. Restrictions live here
  /// and only here — they are never events and never preference evidence.
  func statements(layer: TasteStatementLayer? = nil) throws -> [TasteProfileStatement] {
    try db.read { db in
      let rows: [Row]
      if let layer {
        rows = try Row.fetchAll(
          db,
          sql: "SELECT * FROM taste_statements WHERE layer = ? ORDER BY created_at, id",
          arguments: [layer.rawValue])
      } else {
        rows = try Row.fetchAll(
          db, sql: "SELECT * FROM taste_statements ORDER BY created_at, id")
      }
      return try rows.map { try Self.statement(from: $0) }
    }
  }

  func statementCount() throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taste_statements") ?? 0
    }
  }

  private static func statement(from row: Row) throws -> TasteProfileStatement {
    func layer(_ raw: String?) throws -> TasteStatementLayer {
      guard let raw, let value = TasteStatementLayer(rawValue: raw) else {
        throw TasteStoreError.unknownStatementLayer(raw)
      }
      return value
    }
    func state(_ raw: String?) throws -> TasteStatementState {
      guard let raw, let value = TasteStatementState(rawValue: raw) else {
        throw TasteStoreError.unknownStatementState(raw)
      }
      return value
    }
    func featureKind(_ raw: String?) throws -> TasteFeatureKind? {
      guard let raw else { return nil }
      guard let value = TasteFeatureKind(rawValue: raw) else {
        throw TasteStoreError.unknownFeatureKind(raw)
      }
      return value
    }
    return TasteProfileStatement(
      id: row["id"],
      layer: try layer(row["layer"]),
      featureKind: try featureKind(row["feature_kind"]),
      featureKey: row["feature_key"],
      templateId: row["template_id"],
      numerator: row["numerator"],
      denominator: row["denominator"],
      state: try state(row["state"]),
      mutedUntil: row["muted_until"],
      pinnedValue: row["pinned_value"],
      lastEvidenceAt: row["last_evidence_at"],
      createdAt: row["created_at"],
      updatedAt: row["updated_at"],
      text: row["text"])
  }

  // MARK: - Export and delete

  /// The full taste log in one value, in replay order.
  func exportAll() throws -> TasteExport {
    TasteExport(
      exportedAt: Date(),
      events: try allEvents().map(\.event),
      exposures: try allExposures(),
      statements: try statements())
  }

  /// The full taste log as contract-shaped JSON (ISO-8601 UTC timestamps with
  /// millisecond precision, event payloads exactly as in the contract examples). This is
  /// what a backup archive or a settings "export your data" flow would hand off.
  func exportAllJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(TasteTimestamp.string(from: date))
    }
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(try exportAll())
  }

  /// Deletes every taste event, exposure, and statement. Restrictions are statement
  /// rows, so they are deleted too — resetting the log is a full reset; hard filters
  /// keep working from `health_profile` independently (SPEC §2.3).
  func deleteAll() throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM taste_statements")
      try db.execute(sql: "DELETE FROM taste_exposures")
      try db.execute(sql: "DELETE FROM taste_events")
    }
  }
}

// MARK: - Errors

enum TasteStoreError: LocalizedError {
  case unknownEventKind(String)
  case unknownRecipeSource(String)
  case malformedExposureJSON(String)
  case unknownStatementLayer(String?)
  case unknownStatementState(String?)
  case unknownFeatureKind(String)
  case unresolvableRecipeIdentity(id: String, revision: Int?)

  var errorDescription: String? {
    switch self {
    case .unknownEventKind(let kind):
      return "Taste event log contains an unknown event kind: \(kind)."
    case .unknownRecipeSource(let source):
      return "Taste event log contains an unknown recipe source: \(source)."
    case .malformedExposureJSON(let id):
      return "Taste exposure \(id) contains malformed JSON."
    case .unknownStatementLayer(let layer):
      return "Taste statement has an unknown layer: \(layer ?? "nil")."
    case .unknownStatementState(let state):
      return "Taste statement has an unknown state: \(state ?? "nil")."
    case .unknownFeatureKind(let kind):
      return "Taste statement has an unknown feature kind: \(kind)."
    case .unresolvableRecipeIdentity(let id, let revision):
      return "Taste query keyed on a recipe ref with no source: id \(id), revision \(revision.map(String.init) ?? "nil") —"
        + " the store keys events on (source, id) and would silently match nothing."
    }
  }
}
