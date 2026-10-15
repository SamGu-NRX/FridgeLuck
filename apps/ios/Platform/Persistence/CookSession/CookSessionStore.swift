import FLFeatureLogic
import Foundation
import GRDB

/// ISO-8601 with fractional seconds — the `cook_*` tables store timestamps as TEXT (LeChef §11).
/// A formatter is created per call (matching the repo's other persistence call sites) so no
/// shared mutable formatter state crosses concurrency domains.
enum CookTimestamp {
  private static func makeFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  static func string(_ date: Date) -> String { makeFormatter().string(from: date) }

  static func date(_ string: String) -> Date? { makeFormatter().date(from: string) }
}

extension CookSessionPhase {
  var storageValue: String {
    switch self {
    case .idle: return "idle"
    case .cooking: return "cooking"
    case .remembering: return "remembering"
    case .remembered: return "remembered"
    case .abandoned: return "abandoned"
    }
  }

  static func from(storageValue: String) -> CookSessionPhase? {
    CookSessionPhase(rawValue: storageValue)
  }
}

// MARK: - Rows

struct CookSessionRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_session"

  var id: String
  var recipeRef: String?
  var servings: Int
  var eaterIds: String
  var state: String
  var currentStep: Int
  var completedSteps: String
  var startedAt: String?
  var endedAt: String?
  var revision: Int
  var rating: Int?

  enum CodingKeys: String, CodingKey {
    case id
    case recipeRef = "recipe_ref"
    case servings
    case eaterIds = "eater_ids"
    case state
    case currentStep = "current_step"
    case completedSteps = "completed_steps"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case revision
    case rating
  }
}

struct CookTimerRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_timer"

  var id: String
  var sessionId: String
  var label: String
  var deadline: String
  var pausedAt: String?
  var remainingWhenPausedSeconds: Double?
  var acknowledgedAt: String?
  var totalSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case label
    case deadline
    case pausedAt = "paused_at"
    case remainingWhenPausedSeconds = "remaining_when_paused_seconds"
    case acknowledgedAt = "acknowledged_at"
    case totalSeconds = "total_seconds"
  }
}

struct CookAdaptationRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_adaptation"

  var id: Int64?
  var sessionId: String
  var at: String
  var kind: String
  var input: String
  var applied: String
  var caption: String

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case at
    case kind
    case input
    case applied
    case caption
  }
}

struct CookSubstitutionRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_substitution"

  var id: Int64?
  var sessionId: String?
  var planId: String?
  var originalId: Int64?
  var substituteId: Int64?
  var ratio: Double?
  var note: String
  var allergenRecheck: String?
  var source: String

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case planId = "plan_id"
    case originalId = "original_id"
    case substituteId = "substitute_id"
    case ratio
    case note
    case allergenRecheck = "allergen_recheck"
    case source
  }
}

/// One row per resolved proposal (LeChef §8). `proposal_id` is the primary key, so recording
/// the same proposal twice fails at the database — exactly-once is not a convention.
struct CookReceiptRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_receipt"

  var proposalId: String
  var sessionId: String
  var status: String
  var decidedAt: String
  var decidedBy: String
  var applied: String?
  var failure: String?
  var sessionRevision: Int

  enum CodingKeys: String, CodingKey {
    case proposalId = "proposal_id"
    case sessionId = "session_id"
    case status
    case decidedAt = "decided_at"
    case decidedBy = "decided_by"
    case applied
    case failure
    case sessionRevision = "session_revision"
  }
}

struct CookRememberRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "cook_remember"

  var sessionId: String
  var rating: Int?
  var note: String?
  var savedAt: String?
  var skipped: Bool

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case rating
    case note
    case savedAt = "saved_at"
    case skipped
  }
}

// MARK: - Domain payloads

/// What the store hands back for an active session.
struct ActiveCookSession: Equatable {
  let session: CookSession
  let timers: CookTimerStore
}

/// A proposal receipt as the persistence layer sees it. Status mirrors the wire receipt's
/// states; `applied`/`failure` carry the canonical JSON of whichever side applies.
struct CookStoredReceipt: Equatable, Codable {
  enum Status: String, Codable {
    case executed
    case rejected
    case expired
    case cancelled
  }

  var proposalID: String
  var sessionID: String
  var status: Status
  var decidedAt: Date
  var decidedBy: String
  var appliedJSON: String?
  var failure: String?
  var sessionRevision: Int
}

/// The remember receipt, before or after it is saved.
struct CookRememberEntry: Equatable {
  var sessionID: String
  var rating: Int?
  var note: String?
  var savedAt: Date?
  var skipped: Bool
}

// MARK: - Protocol

/// Persistence for cook sessions (LeChef §11). The view model depends on this protocol; tests
/// inject a scoped in-memory store or a `CookSessionStore` over an ephemeral database.
protocol CookSessionPersisting: Sendable {
  /// Writes the session and its full timer set. The row is upserted by id.
  func persist(session: CookSession, timers: CookTimerStore) throws
  /// The one session whose state is `cooking`, with its timers, or nil.
  func loadActiveSession() throws -> ActiveCookSession?
  /// The receipt already recorded for `proposalID`, if any.
  func receipt(proposalID: String) throws -> CookStoredReceipt?
  /// Records a receipt. A repeat for the same proposal id throws — exactly-once is the
  /// primary key's job.
  func record(receipt: CookStoredReceipt) throws
  func record(adaptation: CookAdaptation, sessionID: String) throws
  func record(substitution: CookSubstitution, sessionID: String?, allergenRecheckJSON: String?) throws
  /// Writes the remember receipt (insert or update — the cook may reopen and edit).
  func record(remember: CookRememberEntry) throws
  func loadRemember(sessionID: String) throws -> CookRememberEntry?
}

// MARK: - Store

/// GRDB-backed `CookSessionPersisting` over the `cook_*` tables. All writes run in one
/// transaction each; the partial unique index on `state = 'cooking'` enforces the one-active-
/// session rule at the database, not by convention.
final class CookSessionStore: CookSessionPersisting, Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func persist(session: CookSession, timers: CookTimerStore) throws {
    let row = CookSessionRow(
      id: session.id,
      recipeRef: session.recipeRef.map(Self.encodeRecipeRef),
      servings: session.servings,
      eaterIds: Self.encodeStringArray(session.eaterIDs),
      state: session.phase.storageValue,
      currentStep: session.currentStep,
      completedSteps: Self.encodeIntArray(session.completedSteps.sorted()),
      startedAt: session.startedAt.map(CookTimestamp.string),
      endedAt: session.endedAt.map(CookTimestamp.string),
      revision: session.revision,
      rating: session.rating)

    try db.write { db in
      try row.save(db)

      let existing = try CookTimerRow
        .filter(Column("session_id") == session.id)
        .fetchAll(db)
      let existingIDs = Set(existing.map(\.id))
      let currentIDs = Set(timers.timers.map(\.id))

      for id in existingIDs.subtracting(currentIDs) {
        _ = try CookTimerRow.deleteOne(db, key: id)
      }
      for timer in timers.timers {
        let timerRow = CookTimerRow(
          id: timer.id,
          sessionId: timer.sessionID,
          label: timer.label,
          deadline: CookTimestamp.string(timer.deadline),
          pausedAt: timer.pausedAt.map(CookTimestamp.string),
          remainingWhenPausedSeconds: timer.remainingWhenPausedSeconds,
          acknowledgedAt: timer.acknowledgedAt.map(CookTimestamp.string),
          totalSeconds: timer.totalSeconds)
        try timerRow.save(db)
      }
    }
  }

  func loadActiveSession() throws -> ActiveCookSession? {
    try db.read { db in
      guard let row = try CookSessionRow
        .filter(Column("state") == CookSessionPhase.cooking.storageValue)
        .order(Column("started_at").desc)
        .fetchOne(db)
      else { return nil }

      let timerRows = try CookTimerRow
        .filter(Column("session_id") == row.id)
        .order(Column("deadline").asc)
        .fetchAll(db)

      let adaptationRows = try CookAdaptationRow
        .filter(Column("session_id") == row.id)
        .order(Column("at").asc)
        .fetchAll(db)

      let substitutionRows = try CookSubstitutionRow
        .filter(Column("session_id") == row.id)
        .order(Column("id").asc)
        .fetchAll(db)

      var session = Self.session(from: row)
      session.attachHistory(
        adaptations: Self.adaptations(from: adaptationRows),
        substitutions: Self.substitutions(from: substitutionRows, at: session.startedAt))

      return ActiveCookSession(
        session: session,
        timers: Self.timers(from: timerRows))
    }
  }

  func receipt(proposalID: String) throws -> CookStoredReceipt? {
    try db.read { db in
      guard let row = try CookReceiptRow.fetchOne(db, key: proposalID) else { return nil }
      return Self.receipt(from: row)
    }
  }

  func record(receipt: CookStoredReceipt) throws {
    let row = CookReceiptRow(
      proposalId: receipt.proposalID,
      sessionId: receipt.sessionID,
      status: receipt.status.rawValue,
      decidedAt: CookTimestamp.string(receipt.decidedAt),
      decidedBy: receipt.decidedBy,
      applied: receipt.appliedJSON,
      failure: receipt.failure,
      sessionRevision: receipt.sessionRevision)

    try db.write { db in
      try row.insert(db)
    }
  }

  func record(adaptation: CookAdaptation, sessionID: String) throws {
    let row = CookAdaptationRow(
      id: nil,
      sessionId: sessionID,
      at: CookTimestamp.string(adaptation.at),
      kind: adaptation.kind.rawValue,
      input: adaptation.input,
      applied: adaptation.applied,
      caption: adaptation.caption)

    try db.write { db in
      try row.insert(db)
    }
  }

  func record(substitution: CookSubstitution, sessionID: String?, allergenRecheckJSON: String?) throws {
    let row = CookSubstitutionRow(
      id: nil,
      sessionId: sessionID,
      planId: nil,
      originalId: Int64(substitution.originalKey),
      substituteId: Int64(substitution.substituteKey),
      ratio: nil,
      note: substitution.note,
      allergenRecheck: allergenRecheckJSON,
      source: substitution.source.rawValue)

    try db.write { db in
      try row.insert(db)
    }
  }

  func record(remember: CookRememberEntry) throws {
    let row = CookRememberRow(
      sessionId: remember.sessionID,
      rating: remember.rating,
      note: remember.note,
      savedAt: remember.savedAt.map(CookTimestamp.string),
      skipped: remember.skipped)

    try db.write { db in
      try row.save(db)
    }
  }

  func loadRemember(sessionID: String) throws -> CookRememberEntry? {
    try db.read { db in
      guard let row = try CookRememberRow.fetchOne(db, key: sessionID) else { return nil }
      return CookRememberEntry(
        sessionID: row.sessionId,
        rating: row.rating,
        note: row.note,
        savedAt: row.savedAt.flatMap(CookTimestamp.date),
        skipped: row.skipped)
    }
  }

  // MARK: Mapping

  static func session(from row: CookSessionRow) -> CookSession {
    let ref = row.recipeRef.flatMap(decodeRecipeRef)
    // Steps are re-derived by the view model from the recipe and attached through
    // CookSession's restore initializer — the row deliberately does not duplicate them.
    return CookSession(
      id: row.id,
      phase: CookSessionPhase.from(storageValue: row.state) ?? .idle,
      recipeRef: ref,
      servings: row.servings,
      eaterIDs: decodeStringArray(row.eaterIds),
      steps: [],
      currentStep: row.currentStep,
      completedSteps: Set(decodeIntArray(row.completedSteps)),
      adaptations: [],
      substitutions: [],
      startedAt: row.startedAt.flatMap(CookTimestamp.date),
      endedAt: row.endedAt.flatMap(CookTimestamp.date),
      revision: row.revision,
      rating: row.rating,
      note: nil,
      rememberSkipped: false)
  }

  static func timers(from rows: [CookTimerRow]) -> CookTimerStore {
    var timers: [CookTimer] = []
    for row in rows {
      guard let deadline = CookTimestamp.date(row.deadline) else { continue }
      timers.append(
        CookTimer(
          id: row.id,
          sessionID: row.sessionId,
          label: row.label,
          deadline: deadline,
          pausedAt: row.pausedAt.flatMap(CookTimestamp.date),
          remainingWhenPausedSeconds: row.remainingWhenPausedSeconds,
          acknowledgedAt: row.acknowledgedAt.flatMap(CookTimestamp.date),
          totalSeconds: row.totalSeconds))
    }
    return CookTimerStore(timers: timers)
  }

  static func adaptations(from rows: [CookAdaptationRow]) -> [CookAdaptation] {
    rows.compactMap { row in
      guard let kind = CookAdaptationKind(rawValue: row.kind), let at = CookTimestamp.date(row.at) else { return nil }
      return CookAdaptation(kind: kind, input: row.input, applied: row.applied, caption: row.caption, at: at)
    }
  }

  static func substitutions(from rows: [CookSubstitutionRow], at fallbackDate: Date?) -> [CookSubstitution] {
    // cook_substitution rows carry no timestamp of their own; the swap order is the row order
    // and the timestamp falls back to the session start.
    let at = fallbackDate ?? Date(timeIntervalSince1970: 0)
    return rows.compactMap { row in
      guard let source = CookSubstitutionSource(rawValue: row.source),
        let originalId = row.originalId,
        let substituteId = row.substituteId
      else { return nil }
      return CookSubstitution(
        originalKey: String(originalId),
        substituteKey: String(substituteId),
        note: row.note,
        source: source,
        at: at)
    }
  }

  static func receipt(from row: CookReceiptRow) -> CookStoredReceipt {
    CookStoredReceipt(
      proposalID: row.proposalId,
      sessionID: row.sessionId,
      status: CookStoredReceipt.Status(rawValue: row.status) ?? .rejected,
      decidedAt: CookTimestamp.date(row.decidedAt) ?? Date(timeIntervalSince1970: 0),
      decidedBy: row.decidedBy,
      appliedJSON: row.applied,
      failure: row.failure,
      sessionRevision: row.sessionRevision)
  }

  static func encodeRecipeRef(_ ref: CookRecipeRef) -> String {
    Self.encodeJSON(["source": ref.source.rawValue, "id": ref.id, "revision": ref.revision])
  }

  static func decodeRecipeRef(_ json: String) -> CookRecipeRef? {
    guard let value = Self.decodeJSON(json) as? [String: Any],
      let sourceRaw = value["source"] as? String,
      let source = CookRecipeSource(rawValue: sourceRaw),
      let id = value["id"] as? String
    else { return nil }
    let revision = (value["revision"] as? Int) ?? 1
    return CookRecipeRef(source: source, id: id, revision: revision)
  }

  static func encodeStringArray(_ values: [String]) -> String {
    Self.encodeJSON(values)
  }

  static func decodeStringArray(_ json: String) -> [String] {
    Self.decodeJSON(json) as? [String] ?? []
  }

  static func encodeIntArray(_ values: [Int]) -> String {
    Self.encodeJSON(values)
  }

  static func decodeIntArray(_ json: String) -> [Int] {
    Self.decodeJSON(json) as? [Int] ?? []
  }

  static func encodeJSON(_ value: Any) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  static func decodeJSON(_ json: String) -> Any? {
    (json.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
  }
}
