import Foundation
import GRDB

/// Continual learning system that records and applies user corrections
/// to Vision label misclassifications.
///
/// Design: Corrections are stored in SQLite and cached in-memory.
/// Auto-correction requires count >= 2 to prevent accidental taps
/// from permanently misclassifying items. Single corrections only
/// influence suggestion order in medium-confidence prompts.
final class LearningService: @unchecked Sendable {
  private let db: DatabaseQueue
  private var cache: [String: CachedCorrection] = [:]
  private let lock = NSLock()

  private struct CachedCorrection {
    let ingredientId: Int64
    let count: Int
  }

  init(db: DatabaseQueue) {
    self.db = db
    loadCache()
  }

  // MARK: - Cache Management

  private func loadCache() {
    do {
      try db.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT vision_label, corrected_ingredient_id, correction_count
            FROM user_corrections
            ORDER BY correction_count DESC
            """)

        lock.lock()
        defer { lock.unlock() }

        for row in rows {
          let label: String = row["vision_label"]
          let key = label.lowercased()
          let candidate = CachedCorrection(
            ingredientId: row["corrected_ingredient_id"],
            count: row["correction_count"]
          )

          // Keep only the highest-frequency correction per label.
          if let existing = cache[key], existing.count >= candidate.count {
            continue
          }
          cache[key] = candidate
        }
      }
    } catch {
      // Non-fatal: cache starts empty, corrections still work via DB
    }
  }

  // MARK: - Record Corrections

  /// Record that the user corrected a Vision label to a specific ingredient.
  func recordCorrection(visionLabel: String, correctedIngredientId: Int64) {
    let key = visionLabel.lowercased()

    do {
      try db.write { db in
        try db.execute(
          sql: """
            INSERT INTO user_corrections
                (vision_label, corrected_ingredient_id, correction_count, last_used_at)
            VALUES (?, ?, 1, CURRENT_TIMESTAMP)
            ON CONFLICT(vision_label, corrected_ingredient_id)
            DO UPDATE SET
                correction_count = correction_count + 1,
                last_used_at = CURRENT_TIMESTAMP
            """, arguments: [key, correctedIngredientId])
      }
    } catch {
      // Log but don't crash — correction just won't persist
    }

    // Refresh the top correction for this label from the DB source of truth.
    do {
      let top = try db.read { db -> CachedCorrection? in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT corrected_ingredient_id, correction_count
              FROM user_corrections
              WHERE vision_label = ?
              ORDER BY correction_count DESC, last_used_at DESC
              LIMIT 1
              """, arguments: [key])
        else {
          return nil
        }
        return CachedCorrection(
          ingredientId: row["corrected_ingredient_id"],
          count: row["correction_count"]
        )
      }

      lock.lock()
      if let top {
        cache[key] = top
      } else {
        cache.removeValue(forKey: key)
      }
      lock.unlock()
    } catch {
      // Non-fatal: cache will self-heal on next app launch.
    }
  }

  // MARK: - Query Corrections

  /// Returns the corrected ingredient ID if the user has corrected this label
  /// at least 2 times (threshold prevents accidental auto-correction).
  func correctedIngredientId(for visionLabel: String) -> Int64? {
    let key = visionLabel.lowercased()
    lock.lock()
    defer { lock.unlock() }

    guard let cached = cache[key], cached.count >= 2 else {
      return nil
    }
    return cached.ingredientId
  }

  /// Returns the suggested correction even with count == 1.
  /// Used to pre-select the right option in medium-confidence prompts.
  func suggestedCorrection(for visionLabel: String) -> Int64? {
    let key = visionLabel.lowercased()
    lock.lock()
    defer { lock.unlock() }
    return cache[key]?.ingredientId
  }
}
