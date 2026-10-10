import Foundation
import GRDB

/// Repository for user-specific data: health profile, badges, preferences.
final class UserDataRepository: Sendable {
  private static let onboardingAgeRange = 13...100

  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - Observations

  /// Observes revisions to cooking history so dashboards can stay in sync
  /// with logged meals, rating updates, and serving adjustments.
  @discardableResult
  @MainActor
  func observeCookingHistoryChanges(
    onError: @escaping @MainActor (Error) -> Void = { _ in },
    onChange: @escaping @MainActor () -> Void
  ) -> AnyDatabaseCancellable {
    ValueObservation
      .tracking { db in
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT
              COUNT(*) AS total_count,
              COALESCE(MAX(id), 0) AS latest_id,
              COALESCE(SUM(COALESCE(rating, 0)), 0) AS rating_checksum,
              COALESCE(SUM(COALESCE(servings_consumed, 0)), 0) AS servings_checksum
            FROM cooking_history
            """
        )

        return CookingHistoryRevisionToken(
          totalCount: row?["total_count"] as? Int ?? 0,
          latestID: row?["latest_id"] as? Int64 ?? 0,
          ratingChecksum: row?["rating_checksum"] as? Int ?? 0,
          servingsChecksum: row?["servings_checksum"] as? Int ?? 0
        )
      }
      .removeDuplicates()
      .start(
        in: db,
        scheduling: .mainActor,
        onError: onError,
        onChange: { _ in
          onChange()
        }
      )
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
      guard let profile = try HealthProfile.fetchOne(db, key: 1) else { return false }
      let hasDisplayName = !profile.normalizedDisplayName.isEmpty
      guard let age = profile.age else { return false }
      return hasDisplayName && Self.onboardingAgeRange.contains(age)
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
          WHERE datetime(cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
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
          SELECT date(cooked_at, 'localtime') as day, COUNT(*) as meals
          FROM cooking_history
          WHERE datetime(cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
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
          SELECT CAST(strftime('%w', cooked_at, 'localtime') AS INTEGER) as weekday,
                 COUNT(*) as meals
          FROM cooking_history
          WHERE datetime(cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
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
                 ch.servings_consumed, ch.portion_multiplier,
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

        // Typed extraction preserves the stored count; an `as? Int` cast fell back to all servings.
        let storedServingsConsumed: Int? = row["servings_consumed"]

        let portionMultiplier: Double = row["portion_multiplier"] ?? 1.0
        let historyId: Int64 = row["history_id"]

        // Macros come from the meal's frozen nutrition snapshot. The fallback
        // serving count is the frozen recipe servings, not the mutable
        // catalog value, so later corrections cannot rewrite what was logged.
        let frozenServings = try NutritionSnapshot.frozenServings(in: db, historyId: historyId)
        let servingsConsumed = storedServingsConsumed ?? frozenServings
        let macros = try NutritionSnapshot.consumedTotals(
          in: db, historyId: historyId, storedServingsConsumed: storedServingsConsumed,
          portionMultiplier: portionMultiplier
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
  /// Each day sums frozen per-line values:
  /// (nutrient / 100 * quantity_grams * swap_ratio / frozen recipe_servings)
  /// * servings_consumed * portion_multiplier. Servings consumed and the
  /// denominator come from the meal's snapshot, so catalog corrections after
  /// logging cannot rewrite the totals.
  ///
  /// Every visible meal must carry a current-version snapshot; a missing one
  /// throws instead of silently re-deriving nutrition from the mutable
  /// catalog. Meals whose recipe row is gone stay excluded, matching the
  /// recipes join this query has always used.
  func dailyMacroTotals(lastDays: Int) throws -> [DailyMacroPoint] {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"

    return try db.read { db in
      try NutritionSnapshot.requireCurrentSnapshots(
        in: db,
        visibleWhere: "datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))",
        arguments: [modifier]
      )

      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT date(ch.cooked_at, 'localtime') AS day,
                 SUM(
                   (l.calories / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
                   * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
                 ) AS total_cal,
                 SUM(
                   (l.protein / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
                   * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
                 ) AS total_pro,
                 SUM(
                   (l.carbs / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
                   * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
                 ) AS total_carb,
                 SUM(
                   (l.fat / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
                   * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
                 ) AS total_fat
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          JOIN cooking_history_nutrition_snapshots s
            ON s.history_id = ch.id AND s.snapshot_version = \(NutritionSnapshot.currentVersion)
          JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id
          WHERE datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
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

  /// Get total macros consumed today, from frozen nutrition snapshots.
  ///
  /// Every visible meal must carry a current-version snapshot; a missing one
  /// throws instead of silently re-deriving nutrition from the mutable
  /// catalog. Meals whose recipe row is gone stay excluded, matching the
  /// recipes join this query has always used.
  func todayMacros() throws -> MacroTotals {
    try db.read { db in
      try NutritionSnapshot.requireCurrentSnapshots(
        in: db,
        visibleWhere: "date(ch.cooked_at, 'localtime') = date('now', 'localtime')"
      )

      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            COALESCE(SUM(
              (l.calories / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
              * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
            ), 0) AS total_cal,
            COALESCE(SUM(
              (l.protein / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
              * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
            ), 0) AS total_pro,
            COALESCE(SUM(
              (l.carbs / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
              * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
            ), 0) AS total_carb,
            COALESCE(SUM(
              (l.fat / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
              * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
            ), 0) AS total_fat
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          JOIN cooking_history_nutrition_snapshots s
            ON s.history_id = ch.id AND s.snapshot_version = \(NutritionSnapshot.currentVersion)
          JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id
          WHERE date(ch.cooked_at, 'localtime') = date('now', 'localtime')
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
}

private struct CookingHistoryRevisionToken: Equatable, Sendable {
  let totalCount: Int
  let latestID: Int64
  let ratingChecksum: Int
  let servingsChecksum: Int
}
