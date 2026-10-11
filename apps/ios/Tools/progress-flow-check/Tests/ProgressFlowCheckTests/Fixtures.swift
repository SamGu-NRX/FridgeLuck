import Foundation
import GRDB
import XCTest

@testable import ProgressFlowCheck

/// Shared fixtures: a fresh per-test database migrated to the latest version,
/// a small ingredient/recipe catalog, and meals logged through the REAL
/// persistence path (`PersonalizationService.recordCooking`, which freezes
/// the nutrition snapshot the reads depend on).
///
/// Portion and date revisions are applied as direct UPDATEs on
/// `cooking_history` — that is the arrival point of an accepted revision in
/// the database (no repository API mutates those columns after logging).
///
/// Run with `TZ=UTC`: the repository buckets days with SQLite 'localtime' and
/// the read model uses `Calendar.current`; UTC keeps both in lockstep.
enum Fixtures {
  // Per-100g values chosen for hand-checkable math.
  //
  // Recipe 1 (2 servings, 200 g of ingredient 1):
  //   per full serving: 100/100 * 200 g = 200 kcal -> /2 servings = 100 kcal
  //   consumed = 100 * servingsConsumed * portionMultiplier
  static let ingredient1 = IngredientSpec(
    id: 1, calories: 100, protein: 10, carbs: 10, fat: 10)

  // Recipe 2 (1 serving, 50 g of ingredient 2): consumed = 100 kcal/serving.
  static let ingredient2 = IngredientSpec(
    id: 2, calories: 200, protein: 5, carbs: 40, fat: 5)

  struct IngredientSpec {
    let id: Int64
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
  }

  struct Stack {
    let queue: DatabaseQueue
    let userData: UserDataRepository
    let personalization: PersonalizationService

    func readModel(
      health: AppleHealthServicing = FakeAppleHealthService()
    ) -> ProgressReadModel {
      ProgressReadModel(
        userDataRepository: userData,
        personalizationService: personalization,
        appleHealthService: health)
    }
  }

  static func makeQueue(
    _ name: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> DatabaseQueue {
    let path = NSTemporaryDirectory() + "pfc-\(name)-\(UUID().uuidString).sqlite"
    var config = Configuration()
    config.foreignKeysEnabled = true
    return try DatabaseQueue(path: path, configuration: config)
  }

  /// Migrates to the latest version and seeds the catalog.
  static func makeStack(_ name: String) throws -> Stack {
    let queue = try makeQueue(name)
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try insertCatalog(db)
    }
    return Stack(
      queue: queue,
      userData: UserDataRepository(db: queue),
      personalization: PersonalizationService(db: queue))
  }

  static func insertCatalog(_ db: Database) throws {
    for ingredient in [ingredient1, ingredient2] {
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          ingredient.id, "Ingredient \(ingredient.id)", ingredient.calories,
          ingredient.protein, ingredient.carbs, ingredient.fat, 0, 0, 0,
        ])
    }

    // Recipe 1: 2 servings, one line of ingredient 1 at 200 g.
    try db.execute(
      sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [Int64(1), "Recipe 1", 15, 2, "cook", 0, "bundled"])
    try db.execute(
      sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, ?, ?, ?)",
      arguments: [Int64(1), Int64(1), true, 200.0, "200 g"])

    // Recipe 2: 1 serving, one line of ingredient 2 at 50 g.
    try db.execute(
      sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [Int64(2), "Recipe 2", 10, 1, "cook", 0, "bundled"])
    try db.execute(
      sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, ?, ?, ?)",
      arguments: [Int64(2), Int64(2), true, 50.0, "50 g"])
  }

  /// Logs a meal through the REAL write path (history + snapshot + streak).
  @discardableResult
  static func logMeal(
    _ stack: Stack,
    recipeId: Int64,
    servingsConsumed: Int? = 1,
    portionMultiplier: Double = 1.0
  ) throws -> Int64 {
    try stack.personalization.recordCooking(
      recipeId: recipeId,
      servingsConsumed: servingsConsumed,
      portionMultiplier: portionMultiplier)
  }

  /// Applies a date revision (the arrival point of an accepted re-date) by
  /// setting cooked_at to local noon on `day` — safely inside the calendar
  /// day under the TZ=UTC test convention.
  static func redateMeal(
    _ stack: Stack, historyId: Int64, day: Date, calendar: Calendar = .current
  ) throws {
    try stack.queue.write { db in
      try db.execute(
        sql: "UPDATE cooking_history SET cooked_at = ? WHERE id = ?",
        arguments: [localNoonString(day, calendar: calendar), historyId])
    }
  }

  static func localNoonString(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d 12:00:00.000",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func day(_ offsetFromToday: Int, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .day, value: -offsetFromToday, to: Date())!
  }

  /// Reads the fields of the SHARED dashboard revision token
  /// (UserDataRepository.observeCookingHistoryChanges) so tests can prove a
  /// revision the shared token misses. Test-side read only; the production
  /// observer is untouched.
  static func legacyDashboardToken(_ queue: DatabaseQueue) throws
    -> (count: Int, latestID: Int64, ratingChecksum: Int, servingsChecksum: Int) {
    try queue.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            COUNT(*) AS total_count,
            COALESCE(MAX(id), 0) AS latest_id,
            COALESCE(SUM(COALESCE(rating, 0)), 0) AS rating_checksum,
            COALESCE(SUM(COALESCE(servings_consumed, 0)), 0) AS servings_checksum
          FROM cooking_history
          """)
      return (
        row?["total_count"] as? Int ?? 0,
        row?["latest_id"] as? Int64 ?? 0,
        row?["rating_checksum"] as? Int ?? 0,
        row?["servings_checksum"] as? Int ?? 0
      )
    }
  }
}

/// Configurable Apple Health stand-in: status, returned totals, and an
/// optional injected error, so source-switch and fallback paths are
/// exercised against the real port shape.
final class FakeAppleHealthService: AppleHealthServicing, @unchecked Sendable {
  var status: PermissionStatus
  var todayTotals: AppleHealthNutritionTotals?
  var dailyDays: [AppleHealthNutritionDay]
  var errorToThrow: Error?

  init(
    status: PermissionStatus = .notDetermined,
    todayTotals: AppleHealthNutritionTotals? = nil,
    dailyDays: [AppleHealthNutritionDay] = [],
    errorToThrow: Error? = nil
  ) {
    self.status = status
    self.todayTotals = todayTotals
    self.dailyDays = dailyDays
    self.errorToThrow = errorToThrow
  }

  func authorizationStatus() -> PermissionStatus { status }

  func authorizationRequestStatus() async -> AppleHealthAuthorizationRequestStatus {
    .unnecessary
  }

  func writeMeal(_ record: AppleHealthMealRecord) async throws {}

  func fetchNutritionTotals(in interval: DateInterval) async throws
    -> AppleHealthNutritionTotals? {
    if let error = errorToThrow { throw error }
    return todayTotals
  }

  func fetchDailyNutritionTotals(lastDays: Int, endingOn endDate: Date) async throws
    -> [AppleHealthNutritionDay] {
    if let error = errorToThrow { throw error }
    return dailyDays
  }
}
