import Foundation
import GRDB

// Fresh file-backed GRDB database with the production schema for the tables
// the replay touches, plus a logical-clock mechanism.
//
// Why the clock: production LearningService stamps last_used_at with SQLite
// CURRENT_TIMESTAMP, which has one-second granularity. A fast replay would
// collapse every event into the same second and silently change the
// last_used_at tie-breaks the policy depends on. Instead of sleeping real
// seconds, the harness installs AFTER INSERT / AFTER UPDATE triggers that
// restamp last_used_at with the event's own logical time (formatted exactly
// like CURRENT_TIMESTAMP, UTC, no millis). Production code is untouched; the
// triggers live only in replay databases, and each event keeps its own
// timestamp so the semantics match the reference model exactly.

enum ReplayDatabase {
  static func timestamp(_ unixSeconds: Int) -> String {
    let epoch = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: epoch)
  }

  static func make(path: String, productIds: [Int64]) throws -> DatabaseQueue {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try ReplaySchema.migrate(db)

      for id in productIds {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO ingredients (id, name, calories, protein, carbs, fat)
            VALUES (?, ?, 0, 0, 0, 0)
            """,
          arguments: [id, "Ingredient-\(id)"])
      }

      try db.execute(
        sql: """
          CREATE TABLE replay_logical_clock (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            ts TEXT NOT NULL
          )
          """)
      try db.execute(
        sql: "INSERT INTO replay_logical_clock (id, ts) VALUES (1, ?)",
        arguments: [timestamp(0)])

      try db.execute(
        sql: """
          CREATE TRIGGER replay_logical_insert AFTER INSERT ON user_corrections
          BEGIN
            UPDATE user_corrections
            SET last_used_at = (SELECT ts FROM replay_logical_clock WHERE id = 1)
            WHERE rowid = NEW.rowid;
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER replay_logical_update AFTER UPDATE OF last_used_at ON user_corrections
          WHEN NEW.last_used_at <> (SELECT ts FROM replay_logical_clock WHERE id = 1)
          BEGIN
            UPDATE user_corrections
            SET last_used_at = (SELECT ts FROM replay_logical_clock WHERE id = 1)
            WHERE rowid = NEW.rowid;
          END
          """)
    }
    return queue
  }

  static func setClock(_ queue: DatabaseQueue, to unixSeconds: Int) throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE replay_logical_clock SET ts = ? WHERE id = 1",
        arguments: [timestamp(unixSeconds)])
    }
  }
}

// MARK: - Policy protocol and tool-only arms

protocol CorrectionPolicy {
  var arm: String { get }
  func recordCorrection(label: String, product: Int64) throws
  func autoCorrect(for label: String) throws -> Int64?
  func restart() throws
  func close() throws
}

/// Baseline: no learning, never auto-corrects.
final class NoLearningPolicy: CorrectionPolicy {
  let arm = "no_learning"
  func recordCorrection(label: String, product: Int64) throws {}
  func autoCorrect(for label: String) throws -> Int64? { nil }
  func restart() throws {}
  func close() throws {}
}

/// The REAL production LearningService over a replay database. This is the
/// arm under test -- not a replica.
final class CurrentPolicy: CorrectionPolicy {
  let arm = "current"
  private let queue: DatabaseQueue
  private var service: LearningService

  init(queue: DatabaseQueue) throws {
    self.queue = queue
    self.service = LearningService(db: queue)
  }

  func recordCorrection(label: String, product: Int64) throws {
    service.recordCorrection(visionLabel: label, correctedIngredientId: product)
  }

  func autoCorrect(for label: String) throws -> Int64? {
    service.correctedIngredientId(for: label)
  }

  func restart() throws {
    // Fresh instance: cache is rebuilt from the database, exactly like
    // relaunching the app.
    service = LearningService(db: queue)
  }

  func close() throws {}

  /// Query through a brand-new service on a brand-new connection to the same
  /// file: the database-restart agreement check.
  func reopenDecision(for label: String, path: String) throws -> Int64? {
    let fresh = try DatabaseQueue(path: path)
    defer { try? fresh.close() }
    let freshService = LearningService(db: fresh)
    return freshService.correctedIngredientId(for: label)
  }
}

/// Bounded alternative 1: bounded state. Only the last `window` feedback
/// events per label are remembered; a stale correction ages out. Auto-correct
/// needs the window-majority product to appear >= 2 times in the window;
/// ties go to the most recent occurrence.
final class RecencyWindowPolicy: CorrectionPolicy {
  let arm = "recency_window"
  static let windowSize = 6

  private let queue: DatabaseQueue

  init(queue: DatabaseQueue) throws {
    self.queue = queue
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS replay_feedback_log (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            norm_label TEXT NOT NULL,
            product INTEGER NOT NULL
          )
          """)
    }
  }

  func recordCorrection(label: String, product: Int64) throws {
    let key = Self.normalize(label)
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO replay_feedback_log (norm_label, product) VALUES (?, ?)",
        arguments: [key, product])
    }
  }

  func autoCorrect(for label: String) throws -> Int64? {
    let key = Self.normalize(label)
    return try queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT product, seq FROM replay_feedback_log
          WHERE norm_label = ?
          ORDER BY seq DESC
          LIMIT ?
          """,
        arguments: [key, RecencyWindowPolicy.windowSize])
      var counts: [Int64: Int] = [:]
      var lastSeq: [Int64: Int] = [:]
      for row in rows {
        let product: Int64 = row["product"]
        counts[product, default: 0] += 1
        if lastSeq[product] == nil { lastSeq[product] = row["seq"] }
      }
      // top by (count, recency); auto needs count >= 2
      let ranked = counts.keys.sorted { lhs, rhs in
        let (lc, rc) = (counts[lhs]!, counts[rhs]!)
        if lc != rc { return lc > rc }
        return lastSeq[lhs]! > lastSeq[rhs]!
      }
      guard let top = ranked.first, counts[top]! >= 2 else { return nil }
      return top
    }
  }

  func restart() throws {}
  func close() throws {}

  static func normalize(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

/// Bounded alternative 2: bounded influence. Same storage shape as the
/// current policy, but (a) a correction that conflicts with the current top
/// choice decrements that stale choice (a conflicting tap is evidence against
/// it), and (b) auto-correction additionally requires a margin of 2 over the
/// runner-up; below the margin the policy abstains (suggest only).
final class ConflictAbstainPolicy: CorrectionPolicy {
  let arm = "conflict_abstain"
  static let margin = 2

  private let queue: DatabaseQueue

  init(queue: DatabaseQueue) throws {
    self.queue = queue
  }

  func recordCorrection(label: String, product: Int64) throws {
    let key = Self.normalize(label)
    try queue.write { db in
      // Decrement the stale leader when the new correction conflicts with it.
      if let top = try Self.top(db, key: key), top.product != product, top.count > 1 {
        try db.execute(
          sql: """
            UPDATE user_corrections
            SET correction_count = correction_count - 1
            WHERE vision_label = ? AND corrected_ingredient_id = ?
            """,
          arguments: [key, top.product])
      }
      try db.execute(
        sql: """
          INSERT INTO user_corrections
              (vision_label, corrected_ingredient_id, correction_count, last_used_at)
          VALUES (?, ?, 1, CURRENT_TIMESTAMP)
          ON CONFLICT(vision_label, corrected_ingredient_id)
          DO UPDATE SET
              correction_count = correction_count + 1,
              last_used_at = CURRENT_TIMESTAMP
          """,
        arguments: [key, product])
    }
  }

  func autoCorrect(for label: String) throws -> Int64? {
    let key = Self.normalize(label)
    return try queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT corrected_ingredient_id, correction_count
          FROM user_corrections
          WHERE vision_label = ?
          ORDER BY correction_count DESC, last_used_at DESC, rowid DESC
          """,
        arguments: [key])
      guard let top = rows.first, let topCount: Int = top["correction_count"], topCount >= 2 else {
        return nil
      }
      if rows.count >= 2, let second: Int = rows[1]["correction_count"], topCount - second < ConflictAbstainPolicy.margin {
        return nil  // abstain: ambiguous evidence
      }
      return top["corrected_ingredient_id"]
    }
  }

  func restart() throws {}
  func close() throws {}

  static func normalize(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func top(_ db: Database, key: String) throws -> (product: Int64, count: Int)? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT corrected_ingredient_id, correction_count
          FROM user_corrections
          WHERE vision_label = ?
          ORDER BY correction_count DESC, last_used_at DESC, rowid DESC
          LIMIT 1
          """,
        arguments: [key])
    else { return nil }
    return (row["corrected_ingredient_id"], row["correction_count"])
  }
}

enum PolicyFactory {
  static func make(arm: String, queue: DatabaseQueue) throws -> CorrectionPolicy {
    switch arm {
    case "no_learning": return NoLearningPolicy()
    case "current": return try CurrentPolicy(queue: queue)
    case "recency_window": return try RecencyWindowPolicy(queue: queue)
    case "conflict_abstain": return try ConflictAbstainPolicy(queue: queue)
    default: fatalError("unknown arm \(arm)")
    }
  }

  static let allArms = ["no_learning", "current", "recency_window", "conflict_abstain"]
}
