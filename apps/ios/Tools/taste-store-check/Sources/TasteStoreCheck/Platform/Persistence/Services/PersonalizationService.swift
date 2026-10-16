import Foundation
import GRDB

import FLFeatureLogic

enum CookingLogError: LocalizedError {
  case swapNotForRequiredIngredient(recipeId: Int64, ingredientId: Int64)
  /// A catalog cook passed `catalogId` without `catalogRevision` (or the reverse) —
  /// the link would be incomplete, so the log is refused rather than half-written.
  case catalogIdentityIncomplete

  var errorDescription: String? {
    switch self {
    case .swapNotForRequiredIngredient(let recipeId, let ingredientId):
      return
        "Swap for ingredient \(ingredientId) isn't a required ingredient of recipe \(recipeId); it would not count toward the meal."
    case .catalogIdentityIncomplete:
      return
        "A catalog cook needs catalogId and catalogRevision together; the history row links to one exact revision or none."
    }
  }
}

/// Computes a personalization score for recipes based on user history.
/// Factors: past ratings, cuisine affinity, variety (recency penalty).
final class PersonalizationService: Sendable {
  private let db: DatabaseQueue
  /// The taste event log over the same database. Meal logging and rating write their
  /// events through it inside the meal log's own transaction (docs/spec/taste/SPEC.md §2.3).
  private let tasteStore: TasteEventStore

  init(db: DatabaseQueue, tasteStore: TasteEventStore? = nil) {
    self.db = db
    self.tasteStore = tasteStore ?? TasteEventStore(db: db)
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
    servingsConsumed: Int? = nil,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    recipeSource: TasteRecipeSource = .catalog,
    exposureId: String? = nil,
    slatePosition: Int? = nil,
    swapMotivation: TasteSwapMotivation = .noneAvailable,
    catalogId: String? = nil,
    catalogRevision: Int? = nil
  ) throws -> Int64 {
    try db.write { db in
      try recordCooking(
        in: db,
        recipeId: recipeId,
        rating: rating,
        imagePath: imagePath,
        servingsConsumed: servingsConsumed,
        portionMultiplier: portionMultiplier,
        swaps: swaps,
        recipeSource: recipeSource,
        exposureId: exposureId,
        slatePosition: slatePosition,
        swapMotivation: swapMotivation,
        catalogId: catalogId,
        catalogRevision: catalogRevision
      )
    }
  }

  /// Transaction-scoped insert used by higher-level services that compose
  /// multiple writes in a single DB transaction.
  ///
  /// The meal log and its taste events — `recipe_cooked` (rating inside the payload when
  /// known at cook time) plus one `ingredient_substituted` per swap — are written here,
  /// so they commit or roll back together (docs/spec/taste/SPEC.md §2.3).
  ///
  /// A catalog cook passes `catalogId` + `catalogRevision`: the history row gains its
  /// `recipes_cooking_catalog_refs` link (same transaction), and the `recipe_cooked`
  /// event names the catalog recipe at that revision — not the legacy integer id —
  /// so the meal's nutrition reports from `recipes_catalog_nutrition` at exactly the
  /// revision that was cooked, immune to later revision bumps.
  func recordCooking(
    in db: Database,
    recipeId: Int64,
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int? = nil,
    portionMultiplier: Double = 1.0,
    swaps: [IngredientSwap] = [],
    recipeSource: TasteRecipeSource = .catalog,
    exposureId: String? = nil,
    slatePosition: Int? = nil,
    swapMotivation: TasteSwapMotivation = .noneAvailable,
    catalogId: String? = nil,
    catalogRevision: Int? = nil
  ) throws -> Int64 {
    // Fail closed on a half-specified catalog identity: a link to "some id, any
    // revision" is exactly the drift this link exists to prevent.
    if (catalogId == nil) != (catalogRevision == nil) {
      throw CookingLogError.catalogIdentityIncomplete
    }

    let history = CookingHistory(
      recipeId: recipeId,
      rating: rating,
      imagePath: imagePath,
      servingsConsumed: servingsConsumed,
      portionMultiplier: portionMultiplier
    )
    try history.insert(db)
    // Read before the streak write below, which replaces the connection's last insert ID.
    let historyID = db.lastInsertedRowID

    if let catalogId, let catalogRevision {
      try db.execute(
        sql: """
          INSERT INTO recipes_cooking_catalog_refs (history_id, catalog_id, revision)
          VALUES (?, ?, ?)
          """,
        arguments: [historyID, catalogId, catalogRevision]
      )
    }

    if !swaps.isEmpty {
      let requiredIDs = try Set(
        Int64.fetchAll(
          db,
          sql: "SELECT ingredient_id FROM recipe_ingredients WHERE recipe_id = ? AND is_required = 1",
          arguments: [recipeId]
        ))
      for swap in swaps where !requiredIDs.contains(swap.originalIngredientId) {
        throw CookingLogError.swapNotForRequiredIngredient(
          recipeId: recipeId, ingredientId: swap.originalIngredientId)
      }
    }
    for swap in swaps {
      try db.execute(
        sql: """
          INSERT INTO cooking_history_swaps
            (history_id, original_ingredient_id, substitute_ingredient_id, ratio)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          historyID, swap.originalIngredientId, swap.substituteIngredientId, swap.ratio,
        ]
      )
    }

    let today = Self.todayString()
    let existing = try Streak.fetchOne(db, key: today)
    if var streak = existing {
      streak.mealsCookedCount += 1
      try streak.update(db)
    } else {
      let streak = Streak(date: today, mealsCookedCount: 1)
      try streak.insert(db)
    }

    // The cook's own event anchors the transaction window; each swap links to it via
    // `cookEventId` so the profile branch merges them into one learning batch
    // (docs/spec/taste/SPEC.md §2.3). Written inside the caller's transaction, so they
    // commit or roll back with the meal log.
    let cookEventID = UUID().uuidString.lowercased()
    // A catalog cook names the catalog recipe at the revision cooked — not the legacy
    // integer id — so taste learning and nutrition reporting resolve the exact revision.
    let ref = TasteRecipeRef(
      id: catalogId ?? String(recipeId),
      revision: catalogRevision ?? 1,
      source: recipeSource.rawValue)
    try tasteStore.append(
      TasteEventRecord(
        id: cookEventID,
        recipe: ref,
        surface: TasteSurface.cookComplete,
        payload: .cooked(
          TasteCookedPayload(
            cookSessionId: nil, exposureId: exposureId, rating: rating, servings: servingsConsumed,
            slatePosition: slatePosition, wouldMakeAgain: nil)),
        cookEventId: cookEventID),
      in: db)
    for swap in swaps {
      try tasteStore.append(
        TasteEventRecord(
          recipe: ref,
          ingredient: swap.originalIngredientId,
          surface: TasteSurface.cookIngredients,
          payload: .substituted(
            TasteSubstitutionPayload(
              cookEventId: cookEventID, motivation: swapMotivation, ratio: swap.ratio,
              substituteIngredientId: swap.substituteIngredientId)),
          cookEventId: cookEventID),
        in: db)
    }

    return historyID
  }

  /// Rate a previously cooked recipe. The rating becomes a `recipe_rated` event that
  /// merges into the cook's transaction window via `cookEventId`, written inside the same
  /// transaction as the rating update (docs/spec/taste/SPEC.md §2.3).
  func rateLastCooking(
    recipeId: Int64,
    rating: Int,
    recipeSource: TasteRecipeSource = .catalog
  ) throws {
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
      let recipeRef = TasteRecipeRef(id: String(recipeId), revision: 1, source: recipeSource.rawValue)
      let cookEventID = try tasteStore.latestCookEventId(for: recipeRef, in: db)
      try tasteStore.append(
        TasteEventRecord(
          recipe: recipeRef,
          surface: TasteSurface.cookComplete,
          payload: .rated(TasteRatedPayload(cookEventId: cookEventID, rating: rating)),
          cookEventId: cookEventID),
        in: db)
    }
  }

  // MARK: - Explicit taste signals

  /// The recipe was shown but not taken ("not tonight"). Skips resolve against their
  /// `exposureId`, so pass the id of the exposure the recipe was shown in
  /// (docs/spec/taste/SPEC.md §2.4).
  func recordSkip(
    recipeId: Int64,
    recipeSource: TasteRecipeSource = .catalog,
    exposureId: String? = nil,
    reason: String? = nil,
    surface: String,
    eater: String? = nil
  ) throws {
    try tasteStore.append(
      TasteEventRecord(
        eater: eater,
        recipe: TasteRecipeRef(id: String(recipeId), revision: 1, source: recipeSource.rawValue),
        surface: surface,
        payload: .skipped(TasteSkippedPayload(exposureId: exposureId, reason: reason))))
  }

  /// A shown recommendation was actively dismissed (swiped away / closed without opening).
  /// Logged as a `recipe_skipped` with reason `dismissed`; pass `exposureId` when the
  /// dismissal happened on a rendered slate.
  func recordDismissal(
    recipeId: Int64,
    recipeSource: TasteRecipeSource = .catalog,
    exposureId: String? = nil,
    surface: String,
    eater: String? = nil
  ) throws {
    try recordSkip(
      recipeId: recipeId,
      recipeSource: recipeSource,
      exposureId: exposureId,
      reason: "dismissed",
      surface: surface,
      eater: eater)
  }

  /// The user said they dislike something ("never suggest this ingredient"). Logged as a
  /// `profile_edited` event; the taste profile branch turns it into a pinned statement.
  func recordExplicitDislike(
    ingredientId: Int64,
    featureKey: String,
    featureKind: TasteFeatureKind = .ingredient,
    surface: String,
    eater: String? = nil
  ) throws {
    try tasteStore.append(
      TasteEventRecord(
        eater: eater,
        ingredient: ingredientId,
        surface: surface,
        payload: .profileEdited(
          TasteProfileEditedPayload(
            featureKey: featureKey,
            featureKind: featureKind,
            op: "never_suggest",
            note: nil))))
  }

  /// An ingredient was removed while cooking — an away-from signal ("You removed
  /// coriander in 4 of the 5 recipes…", docs/spec/taste/SPEC.md §4). Logged as an
  /// `ingredient_substituted` event; `substituteIngredientId` is set only when the
  /// removal went to a specific substitute.
  func recordIngredientRemoval(
    recipeId: Int64,
    ingredientId: Int64,
    recipeSource: TasteRecipeSource = .catalog,
    motivation: TasteSwapMotivation = .preferred,
    substituteIngredientId: Int64? = nil,
    ratio: Double? = nil,
    cookEventId: String? = nil,
    surface: String = TasteSurface.cookIngredients,
    eater: String? = nil
  ) throws {
    try tasteStore.append(
      TasteEventRecord(
        eater: eater,
        recipe: TasteRecipeRef(id: String(recipeId), revision: 1, source: recipeSource.rawValue),
        ingredient: ingredientId,
        surface: surface,
        payload: .substituted(
          TasteSubstitutionPayload(
            cookEventId: cookEventId,
            motivation: motivation,
            ratio: ratio,
            substituteIngredientId: substituteIngredientId))))
  }

  /// The user saved a recipe to their cookbook.
  func recordSave(
    recipeId: Int64,
    recipeSource: TasteRecipeSource = .catalog,
    exposureId: String? = nil,
    surface: String = TasteSurface.recipeDetail,
    eater: String? = nil
  ) throws {
    try tasteStore.append(
      TasteEventRecord(
        eater: eater,
        recipe: TasteRecipeRef(id: String(recipeId), revision: 1, source: recipeSource.rawValue),
        surface: surface,
        payload: .saved(TasteSavedPayload(exposureId: exposureId))))
  }

  /// The user removed a saved recipe from their cookbook.
  func recordUnsave(
    recipeId: Int64,
    recipeSource: TasteRecipeSource = .catalog,
    surface: String = TasteSurface.cookbookSaved,
    eater: String? = nil
  ) throws {
    try tasteStore.append(
      TasteEventRecord(
        eater: eater,
        recipe: TasteRecipeRef(id: String(recipeId), revision: 1, source: recipeSource.rawValue),
        surface: surface,
        payload: .unsaved(TasteUnsavedPayload())))
  }

  /// Logs one recommendation-surface render (slate + feasible set). The residual ranker
  /// resolves skips, views and opens against the returned record's id
  /// (docs/spec/taste/SPEC.md §2.4).
  func logExposure(_ exposure: TasteExposureRecord) throws {
    try tasteStore.logExposure(exposure)
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

      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
      let recordedDays = rows.compactMap { row -> Date? in
        guard row.mealsCookedCount > 0, let rowDate = Self.parseDate(row.date) else { return nil }
        let rowDay = calendar.startOfDay(for: rowDate)
        return rowDay <= today ? rowDay : nil
      }

      guard let firstRecordedDay = recordedDays.first else { return 0 }
      guard firstRecordedDay == today || firstRecordedDay == yesterday else { return 0 }

      var streak = 1
      var expectedDate =
        calendar.date(byAdding: .day, value: -1, to: firstRecordedDay) ?? firstRecordedDay

      for rowDay in recordedDays.dropFirst() {
        if rowDay == expectedDate {
          streak += 1
          expectedDate = calendar.date(byAdding: .day, value: -1, to: expectedDate) ?? expectedDate
        } else if rowDay < expectedDate {
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
