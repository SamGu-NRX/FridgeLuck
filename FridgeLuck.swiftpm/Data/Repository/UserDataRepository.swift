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

  // MARK: - Cooking Journal (Recipe Book)

  /// Fetch all cooking history entries joined with recipe data and computed macros.
  /// Sorted newest-first. Used to populate the Recipe Book collection.
  func cookingJournal(limit: Int? = nil) throws -> [CookingJournalEntry] {
    try db.read { db in
      let limitClause = limit.map { "LIMIT \($0)" } ?? ""
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ch.id AS history_id, ch.cooked_at, ch.rating, ch.image_path,
                 ch.servings_consumed,
                 r.id AS recipe_id, r.title, r.time_minutes, r.servings,
                 r.instructions, r.tags, r.source, r.created_at
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          ORDER BY ch.cooked_at DESC
          \(limitClause)
          """
      )

      return try rows.map { row in
        let recipe = Recipe(
          id: row["recipe_id"],
          title: row["title"],
          timeMinutes: row["time_minutes"],
          servings: row["servings"],
          instructions: row["instructions"],
          tags: row["tags"],
          source: RecipeSource(rawValue: row["source"] as String) ?? .bundled,
          createdAt: row["created_at"]
        )

        let servingsConsumed: Int = row["servings_consumed"] as? Int ?? recipe.servings
        let recipeId: Int64 = row["recipe_id"]

        let macros = try Self.computeConsumedMacros(
          db: db, recipeId: recipeId,
          recipeServings: recipe.servings, servingsConsumed: servingsConsumed
        )

        return CookingJournalEntry(
          id: row["history_id"],
          recipe: recipe,
          cookedAt: row["cooked_at"] as? Date ?? Date(),
          rating: row["rating"],
          imagePath: row["image_path"],
          servingsConsumed: servingsConsumed,
          macrosConsumed: macros
        )
      }
    }
  }

  // MARK: - Daily Macro Totals (for charting)

  /// Compute total macros consumed per day for the last N days.
  /// Each day sums: (nutrient_per_100g / 100 * quantity_grams / recipe_servings) * servings_consumed
  func dailyMacroTotals(lastDays: Int) throws -> [DailyMacroPoint] {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"

    return try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT date(ch.cooked_at) AS day,
                 SUM(
                   (i.calories / 100.0 * ri.quantity_grams / r.servings)
                   * COALESCE(ch.servings_consumed, r.servings)
                 ) AS total_cal,
                 SUM(
                   (i.protein / 100.0 * ri.quantity_grams / r.servings)
                   * COALESCE(ch.servings_consumed, r.servings)
                 ) AS total_pro,
                 SUM(
                   (i.carbs / 100.0 * ri.quantity_grams / r.servings)
                   * COALESCE(ch.servings_consumed, r.servings)
                 ) AS total_carb,
                 SUM(
                   (i.fat / 100.0 * ri.quantity_grams / r.servings)
                   * COALESCE(ch.servings_consumed, r.servings)
                 ) AS total_fat
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          JOIN recipe_ingredients ri ON ri.recipe_id = r.id
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ch.cooked_at >= datetime('now', ?)
          GROUP BY day
          ORDER BY day ASC
          """,
        arguments: [modifier]
      )

      let macrosByDay = Dictionary(
        uniqueKeysWithValues: rows.compactMap {
          row -> (String, (Double, Double, Double, Double))? in
          guard let day: String = row["day"] else { return nil }
          let cal: Double = row["total_cal"] as? Double ?? 0
          let pro: Double = row["total_pro"] as? Double ?? 0
          let carb: Double = row["total_carb"] as? Double ?? 0
          let fat: Double = row["total_fat"] as? Double ?? 0
          return (day, (cal, pro, carb, fat))
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
        let (cal, pro, carb, fat) = macrosByDay[key] ?? (0, 0, 0, 0)
        return DailyMacroPoint(date: date, calories: cal, protein: pro, carbs: carb, fat: fat)
      }
    }
  }

  // MARK: - Today's Macros

  /// Get total macros consumed today.
  func todayMacros() throws -> MacroTotals {
    try db.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            COALESCE(SUM(
              (i.calories / 100.0 * ri.quantity_grams / r.servings)
              * COALESCE(ch.servings_consumed, r.servings)
            ), 0) AS total_cal,
            COALESCE(SUM(
              (i.protein / 100.0 * ri.quantity_grams / r.servings)
              * COALESCE(ch.servings_consumed, r.servings)
            ), 0) AS total_pro,
            COALESCE(SUM(
              (i.carbs / 100.0 * ri.quantity_grams / r.servings)
              * COALESCE(ch.servings_consumed, r.servings)
            ), 0) AS total_carb,
            COALESCE(SUM(
              (i.fat / 100.0 * ri.quantity_grams / r.servings)
              * COALESCE(ch.servings_consumed, r.servings)
            ), 0) AS total_fat
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          JOIN recipe_ingredients ri ON ri.recipe_id = r.id
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE date(ch.cooked_at) = date('now')
          """
      )

      guard let row else { return .zero }
      return MacroTotals(
        calories: row["total_cal"] as? Double ?? 0,
        protein: row["total_pro"] as? Double ?? 0,
        carbs: row["total_carb"] as? Double ?? 0,
        fat: row["total_fat"] as? Double ?? 0
      )
    }
  }

  // MARK: - Average Rating

  /// Average star rating across all cooked meals with ratings.
  func averageRating() throws -> Double? {
    try db.read { db in
      try Double.fetchOne(
        db,
        sql: "SELECT AVG(rating) FROM cooking_history WHERE rating IS NOT NULL"
      )
    }
  }

  // MARK: - Update Rating

  /// Update the rating on a specific cooking history entry.
  func updateRating(historyId: Int64, rating: Int) throws {
    try db.write { db in
      try db.execute(
        sql: "UPDATE cooking_history SET rating = ? WHERE id = ?",
        arguments: [rating, historyId]
      )
    }
  }

  // MARK: - Macro Helpers

  /// Compute absolute macros consumed for a single cooking event.
  private static func computeConsumedMacros(
    db: Database, recipeId: Int64, recipeServings: Int, servingsConsumed: Int
  ) throws -> MacroTotals {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(i.calories / 100.0 * ri.quantity_grams), 0) AS total_cal,
          COALESCE(SUM(i.protein / 100.0 * ri.quantity_grams), 0) AS total_pro,
          COALESCE(SUM(i.carbs / 100.0 * ri.quantity_grams), 0) AS total_carb,
          COALESCE(SUM(i.fat / 100.0 * ri.quantity_grams), 0) AS total_fat
        FROM recipe_ingredients ri
        JOIN ingredients i ON i.id = ri.ingredient_id
        WHERE ri.recipe_id = ?
        """,
      arguments: [recipeId]
    )

    guard let row else { return .zero }
    let servingsFactor = Double(servingsConsumed) / Double(max(recipeServings, 1))
    return MacroTotals(
      calories: (row["total_cal"] as? Double ?? 0) * servingsFactor,
      protein: (row["total_pro"] as? Double ?? 0) * servingsFactor,
      carbs: (row["total_carb"] as? Double ?? 0) * servingsFactor,
      fat: (row["total_fat"] as? Double ?? 0) * servingsFactor
    )
  }
}
