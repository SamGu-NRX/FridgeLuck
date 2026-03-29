import Foundation
import GRDB

/// Computes a personalization score for recipes based on user history.
/// Factors: past ratings, cuisine affinity, variety (recency penalty).
final class PersonalizationService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// Compute personalization boost/penalty for a recipe (-1.0 to +1.0 range).
  func personalScore(for recipeId: Int64) throws -> Double {
    try db.read { db in
      var score: Double = 0

      // Boost recipes user has cooked and liked
      if let avgRating = try Double.fetchOne(
        db,
        sql: """
          SELECT AVG(rating) FROM cooking_history
          WHERE recipe_id = ? AND rating IS NOT NULL
          """, arguments: [recipeId])
      {
        // 5-star → +0.4, 3-star → 0, 1-star → -0.4
        score += (avgRating - 3.0) * 0.2
      }

      // Boost same-tag recipes user frequently cooks (past 30 days)
      let tagAffinity =
        try Double.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM cooking_history ch
            JOIN recipes r ON r.id = ch.recipe_id
            JOIN recipes target ON target.id = ?
            WHERE (r.tags & target.tags) > 0
            AND ch.cooked_at > datetime('now', '-30 days')
            """, arguments: [recipeId]) ?? 0
      score += min(0.3, tagAffinity * 0.03)

      // Penalize recently cooked (promote variety)
      let daysSinceLast = try Double.fetchOne(
        db,
        sql: """
          SELECT julianday('now') - julianday(MAX(cooked_at))
          FROM cooking_history WHERE recipe_id = ?
          """, arguments: [recipeId])

      if let days = daysSinceLast, days < 3 {
        score -= 0.3 * (1.0 - days / 3.0)
      }

      return score
    }
  }

  // MARK: - Record cooking event

  @discardableResult
  func recordCooking(
    recipeId: Int64,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int? = nil
  ) throws -> Int64 {
    try db.write { db in
      try recordCooking(
        in: db,
        recipeId: recipeId,
        rating: rating,
        imagePath: imagePath,
        servingsConsumed: servingsConsumed
      )
    }
  }

  /// Transaction-scoped insert used by higher-level services that compose
  /// multiple writes in a single DB transaction.
  func recordCooking(
    in db: Database,
    recipeId: Int64,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int? = nil
  ) throws -> Int64 {
    let history = CookingHistory(
      recipeId: recipeId,
      rating: rating,
      imagePath: imagePath,
      servingsConsumed: servingsConsumed
    )
    try history.insert(db)

    let today = Self.todayString()
    let existing = try Streak.fetchOne(db, key: today)
    if var streak = existing {
      streak.mealsCookedCount += 1
      try streak.update(db)
    } else {
      let streak = Streak(date: today, mealsCookedCount: 1)
      try streak.insert(db)
    }

    return db.lastInsertedRowID
  }

  /// Rate a previously cooked recipe.
  func rateLastCooking(recipeId: Int64, rating: Int) throws {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE cooking_history
          SET rating = ?
          WHERE id = (
              SELECT id FROM cooking_history
              WHERE recipe_id = ?
              ORDER BY cooked_at DESC
              LIMIT 1
          )
          """, arguments: [rating, recipeId])
    }
  }

  // MARK: - Stats

  func weekActivity() throws -> [Bool] {
    try db.read { db in
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let weekday = calendar.component(.weekday, from: today)
      let daysFromMonday = (weekday + 5) % 7
      guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else {
        return Array(repeating: false, count: 7)
      }

      var result = Array(repeating: false, count: 7)
      for offset in 0..<7 {
        guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
        let dayString = Self.formatDate(day)
        if let streak = try Streak.fetchOne(db, key: dayString), streak.mealsCookedCount > 0 {
          result[offset] = true
        }
      }
      return result
    }
  }

  func currentStreak() throws -> Int {
    try db.read { db in
      let rows = try Streak.order(Streak.Columns.date.desc).fetchAll(db)
      guard !rows.isEmpty else { return 0 }

      var streak = 0
      let calendar = Calendar.current
      var expectedDate = calendar.startOfDay(for: Date())

      for row in rows {
        guard let rowDate = Self.parseDate(row.date) else { break }
        let rowDay = calendar.startOfDay(for: rowDate)

        if rowDay == expectedDate {
          streak += 1
          expectedDate = calendar.date(byAdding: .day, value: -1, to: expectedDate)!
        } else {
          break
        }
      }

      return streak
    }
  }

  private static func formatDate(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    guard
      let year = components.year,
      let month = components.month,
      let day = components.day
    else {
      return ""
    }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  private static func todayString() -> String {
    formatDate(Date())
  }

  private static func parseDate(_ string: String) -> Date? {
    let parts = string.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    guard
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else {
      return nil
    }
    return Calendar.current.date(
      from: DateComponents(year: year, month: month, day: day)
    )
  }
}
