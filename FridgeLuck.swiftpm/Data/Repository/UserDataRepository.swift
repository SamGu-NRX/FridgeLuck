import Foundation
import GRDB

/// Repository for user-specific data: health profile, badges, preferences.
final class UserDataRepository: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - Health Profile

  func fetchHealthProfile() throws -> HealthProfile {
    try db.read { db in
      try HealthProfile.fetchOne(db, key: 1) ?? .default
    }
  }

  func saveHealthProfile(_ profile: HealthProfile) throws {
    try db.write { db in
      var mutable = profile
      mutable.id = 1
      try mutable.save(db)
    }
  }

  func hasCompletedOnboarding() throws -> Bool {
    try db.read { db in
      (try HealthProfile.fetchOne(db, key: 1)) != nil
    }
  }

  // MARK: - Badges

  func earnBadge(id: String) throws {
    try db.write { db in
      let badge = Badge(id: id)
      try badge.insert(db)
    }
  }

  func earnedBadges() throws -> [Badge] {
    try db.read { db in
      try Badge.order(Badge.Columns.earnedAt.desc).fetchAll(db)
    }
  }

  func hasBadge(id: String) throws -> Bool {
    try db.read { db in
      (try Badge.fetchOne(db, key: id)) != nil
    }
  }

  // MARK: - Stats

  func totalMealsCooked() throws -> Int {
    try db.read { db in
      try CookingHistory.fetchCount(db)
    }
  }

  func totalRecipesUsed() throws -> Int {
    try db.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(DISTINCT recipe_id) FROM cooking_history
          """) ?? 0
    }
  }

  func mealsCooked(lastDays: Int) throws -> Int {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"

    return try db.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*)
          FROM cooking_history
          WHERE cooked_at >= datetime('now', ?)
          """,
        arguments: [modifier]
      ) ?? 0
    }
  }

  /// Get the most recent photo path for a recipe, if any.
  func latestPhotoPath(forRecipeId recipeId: Int64) throws -> String? {
    try db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT image_path FROM cooking_history
          WHERE recipe_id = ? AND image_path IS NOT NULL
          ORDER BY cooked_at DESC
          LIMIT 1
          """,
        arguments: [recipeId]
      )
    }
  }

  // MARK: - Reset All User Data

  /// Deletes all user-generated data from the database:
  /// health profile, cooking history, badges, streaks, and user corrections.
  /// Bundled content (recipes, ingredients, dish templates, aliases) is preserved.
  func resetAllUserData() throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM health_profile")
      try db.execute(sql: "DELETE FROM cooking_history")
      try db.execute(sql: "DELETE FROM badges")
      try db.execute(sql: "DELETE FROM streaks")
      try db.execute(sql: "DELETE FROM user_corrections")
    }
  }

  func mealsByDay(lastDays: Int) throws -> [DailyCookingPoint] {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"

    return try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT date(cooked_at) as day, COUNT(*) as meals
          FROM cooking_history
          WHERE cooked_at >= datetime('now', ?)
          GROUP BY day
          ORDER BY day ASC
          """,
        arguments: [modifier]
      )

      let mealsByDay = Dictionary(
        uniqueKeysWithValues: rows.compactMap { row in
          let day: String = row["day"]
          let meals: Int = row["meals"]
          return (day, meals)
        })

      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.locale = Locale(identifier: "en_US_POSIX")

      return (0..<safeDays).reversed().compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
          return nil
        }
        let key = formatter.string(from: date)
        return DailyCookingPoint(date: date, meals: mealsByDay[key] ?? 0)
      }
    }
  }

  func mealsByWeekday(lastDays: Int) throws -> [WeekdayCookingPoint] {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"

    return try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT CAST(strftime('%w', cooked_at) AS INTEGER) as weekday,
                 COUNT(*) as meals
          FROM cooking_history
          WHERE cooked_at >= datetime('now', ?)
          GROUP BY weekday
          """,
        arguments: [modifier]
      )

      let mealsByWeekday = Dictionary(
        uniqueKeysWithValues: rows.compactMap { row in
          let weekday: Int = row["weekday"]  // Sunday = 0
          let meals: Int = row["meals"]
          return (weekday, meals)
        })

      let orderedDays: [(index: Int, label: String, sqlWeekday: Int)] = [
        (1, "Mon", 1),
        (2, "Tue", 2),
        (3, "Wed", 3),
        (4, "Thu", 4),
        (5, "Fri", 5),
        (6, "Sat", 6),
        (7, "Sun", 0),
      ]

      return orderedDays.map { day in
        WeekdayCookingPoint(
          weekdayIndex: day.index,
          weekdayLabel: day.label,
          meals: mealsByWeekday[day.sqlWeekday] ?? 0
        )
      }
    }
  }
}
