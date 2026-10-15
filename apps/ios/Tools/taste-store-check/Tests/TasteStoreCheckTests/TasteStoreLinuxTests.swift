import Foundation
import GRDB
import XCTest

@testable import TasteStoreCheck

/// The taste event log, run on Linux through the mirrored production sources
/// (see Tools/taste-store-check/Scripts/refresh.sh). The app's full migration chain lives
/// in the iOS target, so these tests build the few core tables the meal log touches by
/// hand and then run the taste subsystem migrations; the complete chain plus the iOS-only
/// targets are covered by macOS CI (run_ios_tests.sh).
final class TasteStoreLinuxTests: XCTestCase {
  // MARK: - Fixtures

  /// Core tables the meal log touches, matching their shipped schema in
  /// Platform/Persistence/Database/Migrations.swift.
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
      try db.create(table: "recipes") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("title", .text).notNull()
        t.column("time_minutes", .integer).notNull()
        t.column("servings", .integer).notNull().defaults(to: 1)
        t.column("instructions", .text).notNull()
        t.column("tags", .integer).defaults(to: 0)
        t.column("source", .text).defaults(to: "bundled")
        t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }
      try db.create(table: "ingredients") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull().unique()
        t.column("calories", .double).notNull()
        t.column("protein", .double).notNull()
        t.column("carbs", .double).notNull()
        t.column("fat", .double).notNull()
        t.column("fiber", .double).notNull().defaults(to: 0)
        t.column("sugar", .double).notNull().defaults(to: 0)
        t.column("sodium", .double).notNull().defaults(to: 0)
        t.column("typical_unit", .text)
        t.column("storage_tip", .text)
      }
      try db.create(table: "recipe_ingredients") { t in
        t.column("recipe_id", .integer).notNull().references("recipes", onDelete: .cascade)
        t.column("ingredient_id", .integer).notNull().references("ingredients")
        t.column("is_required", .boolean).notNull().defaults(to: true)
        t.column("quantity_grams", .double).notNull()
        t.column("display_quantity", .text).notNull()
        t.primaryKey(["recipe_id", "ingredient_id"])
      }
      try db.create(table: "cooking_history") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("recipe_id", .integer).notNull().references("recipes")
        t.column("cooked_at", .datetime)
        t.column("rating", .integer).check { $0 >= 1 && $0 <= 5 }
        t.column("image_path", .text)
        t.column("servings_consumed", .integer)
        t.column("portion_multiplier", .double).notNull().defaults(to: 1.0)
      }
      try db.create(table: "cooking_history_swaps") { t in
        t.column("history_id", .integer).notNull()
          .references("cooking_history", onDelete: .cascade)
        t.column("original_ingredient_id", .integer).notNull()
        t.column("substitute_ingredient_id", .integer).notNull().references("ingredients")
        t.column("ratio", .double).notNull().check { $0 > 0 }
        t.primaryKey(["history_id", "original_ingredient_id"])
      }
      try db.create(table: "streaks") { t in
        t.primaryKey("date", .text)
        t.column("meals_cooked", .integer).defaults(to: 0)
      }
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Test Rice', 10, 1, 'Cook.')
          """)
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (10, 'Chicken', 165, 31, 0, 3.6), (11, 'Tofu', 80, 8, 2, 4.8)
          """)
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 10, 1, 100, '100 g')
          """)

    }
    var migrator = DatabaseMigrator()
    TasteMigrations.register(in: &migrator)
    try migrator.migrate(dbQueue)
    return dbQueue
  }

  private func makeStore() throws -> TasteEventStore {
    TasteEventStore(db: try makeMigratedDatabase())
  }

  private func cookedEvent(
    id: String = UUID().uuidString.lowercased(),
    at: Date = Date(timeIntervalSince1970: 1_000_000),
    recipeId: String = "1",
    rating: Int? = 2
  ) -> TasteEvent {
    TasteEvent(
      id: id,
      at: at,
      recipe: TasteRecipeRef(source: .catalog, id: recipeId),
      surface: TasteSurface.cookComplete,
      payload: .cooked(
        TasteCookedPayload(
          cookSessionId: nil, exposureId: nil, rating: rating, servings: 2,
          slatePosition: nil, wouldMakeAgain: nil)))
  }

  // MARK: - Idempotent append

  func testAppendingTheSameEventIdTwiceIsANoOp() throws {
    let store = try makeStore()
    let event = cookedEvent()

    XCTAssertTrue(try store.append(event))
    XCTAssertFalse(try store.append(event), "replaying a stable event id must not insert again")
    XCTAssertEqual(try store.eventCount(), 1)
    XCTAssertTrue(try store.containsEvent(id: event.id))
  }

  func testEventsRoundTripThroughStorage() throws {
    let store = try makeStore()
    let event = cookedEvent()

    try store.append(event)

    let stored = try store.events(recipe: TasteRecipeRef(source: .catalog, id: "1"))
    XCTAssertEqual(stored, [event])
    XCTAssertEqual(stored.first?.kind, .recipeCooked)
  }

  // MARK: - Meal log and events commit or roll back together

  func testMealLogAndItsTasteEventsCommitTogether() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)

    _ = try service.recordCooking(recipeId: 1, rating: 2, servingsConsumed: 2)

    try dbQueue.read { db in
      let historyCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = 1")
      XCTAssertEqual(historyCount, 1)
    }
    let store = TasteEventStore(db: dbQueue)
    let events = try store.allEvents()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.kind, .recipeCooked)
    guard case .cooked(let payload)? = events.first?.payload else {
      return XCTFail("expected a recipe_cooked event")
    }
    XCTAssertEqual(payload.rating, 2)
    XCTAssertEqual(payload.servings, 2)
    XCTAssertNotNil(events.first?.cookEventId, "the cook event carries its transaction id")
  }

  func testFailedMealLogRollsItsTasteEventsBackWithIt() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)
    // A swap for an ingredient the recipe does not require makes the log throw.
    let bogusSwap = IngredientSwap(
      originalIngredientId: 99, substituteIngredientId: 11, ratio: 1.0)

    XCTAssertThrowsError(
      try service.recordCooking(recipeId: 1, servingsConsumed: 1, swaps: [bogusSwap])
    )

    try dbQueue.read { db in
      let historyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cooking_history")
      XCTAssertEqual(historyCount, 0, "the meal log rolled back")
      let swapCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cooking_history_swaps")
      XCTAssertEqual(swapCount, 0)
    }
    let store = TasteEventStore(db: dbQueue)
    XCTAssertEqual(
      try store.eventCount(), 0, "the cook's taste events rolled back with the meal log")
  }

  func testSwapsWriteSubstitutionEventsInTheSameTransaction() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)
    let swap = IngredientSwap(
      originalIngredientId: 10, substituteIngredientId: 11, ratio: 1.0)

    _ = try service.recordCooking(recipeId: 1, servingsConsumed: 1, swaps: [swap])

    let store = TasteEventStore(db: dbQueue)
    let substitutionEvents = try store.events(ingredientId: 10)
    XCTAssertEqual(substitutionEvents.count, 1)
    XCTAssertEqual(substitutionEvents.first?.kind, .ingredientSubstituted)
    guard case .substituted(let payload)? = substitutionEvents.first?.payload else {
      return XCTFail("expected an ingredient_substituted event")
    }
    XCTAssertEqual(payload.substituteIngredientId, 11)
    XCTAssertEqual(payload.motivation, .noneAvailable)
    let cookEvents = try store.allEvents().filter { $0.kind == .recipeCooked }
    XCTAssertEqual(
      payload.cookEventId, cookEvents.first?.cookEventId,
      "the substitution merges into the cook's transaction window")
  }

  func testRateLastCookingWritesARatedEventLinkedToTheCook() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)

    _ = try service.recordCooking(recipeId: 1, servingsConsumed: 1)
    try service.rateLastCooking(recipeId: 1, rating: 4)

    let store = TasteEventStore(db: dbQueue)
    let events = try store.allEvents()
    // Same-millisecond events order by random id — find the cook by kind, not position.
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(Set(events.map(\.kind)), [.recipeCooked, .recipeRated])
    let cooked = try XCTUnwrap(events.first { $0.kind == .recipeCooked })
    let rated = try XCTUnwrap(events.first { $0.kind == .recipeRated })
    guard case .rated(let payload) = rated.payload else {
      return XCTFail("expected a recipe_rated event")
    }
    XCTAssertEqual(payload.rating, 4)
    XCTAssertEqual(
      payload.cookEventId, cooked.cookEventId,
      "the rating merges into the cook's transaction window")
  }

  // MARK: - Queries

  func testEventQueriesByRecipeIngredientAndTimeWindow() throws {
    let store = try makeStore()
    let early = Date(timeIntervalSince1970: 1_000_000)
    let middle = Date(timeIntervalSince1970: 2_000_000)
    let late = Date(timeIntervalSince1970: 3_000_000)

    try store.append(cookedEvent(id: UUID().uuidString.lowercased(), at: early, recipeId: "1"))
    try store.append(
      TasteEvent(
        id: UUID().uuidString.lowercased(),
        at: middle,
        recipe: TasteRecipeRef(source: .catalog, id: "2"),
        ingredient: 101,
        surface: TasteSurface.cookIngredients,
        payload: .substituted(
          TasteSubstitutionPayload(
            cookEventId: nil, motivation: .preferred, ratio: 1.0,
            substituteIngredientId: 105))))
    try store.append(cookedEvent(id: UUID().uuidString.lowercased(), at: late, recipeId: "1"))

    XCTAssertEqual(try store.events(recipe: TasteRecipeRef(source: .catalog, id: "1")).count, 2)
    XCTAssertEqual(
      try store.events(recipe: TasteRecipeRef(source: .user, id: "1")).count, 0,
      "recipe queries match on source and id")
    XCTAssertEqual(try store.events(ingredientId: 101).count, 1)

    let window = try store.events(from: early.addingTimeInterval(-1), to: middle)
    XCTAssertEqual(window.map(\.at), [early, middle], "window bounds are inclusive")

    let ordered = try store.allEvents()
    XCTAssertEqual(ordered.map(\.at), [early, middle, late], "events sort by at, id")
  }

  // MARK: - Restrictions are not preferences

  func testRestrictionsLiveInStatementsAndNeverEnterTheEventLog() throws {
    let store = try makeStore()
    let restriction = TasteProfileStatement(
      id: UUID().uuidString.lowercased(),
      layer: .restriction,
      featureKind: nil,
      featureKey: nil,
      templateId: "restriction.setup.allergy",
      numerator: nil,
      denominator: nil,
      state: .active,
      mutedUntil: nil,
      pinnedValue: nil,
      lastEvidenceAt: nil,
      createdAt: Date(timeIntervalSince1970: 1_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_000_000),
      text: "No shellfish.")

    try store.upsertStatement(restriction)

    XCTAssertEqual(try store.eventCount(), 0, "restrictions are never preference events")
    XCTAssertEqual(try store.statementCount(), 1)
    let stored = try store.statements(layer: .restriction)
    XCTAssertEqual(stored, [restriction])
    XCTAssertEqual(stored.first?.layer, .restriction)
    XCTAssertNil(stored.first?.numerator, "restriction sentences carry no evidence counts")
  }

  // MARK: - Exposures

  func testExposureRoundTripAndIdempotentRelog() throws {
    let store = try makeStore()
    let exposure = TasteExposure(
      id: UUID().uuidString.lowercased(),
      at: Date(timeIntervalSince1970: 1_000_000),
      surface: TasteSurface.homeTonight,
      eater: nil,
      sessionId: "sess-1",
      slate: [
        TasteExposureItem(recipe: TasteRecipeRef(source: .catalog, id: "1"), position: 1),
        TasteExposureItem(recipe: TasteRecipeRef(source: .catalog, id: "2"), position: 2),
      ],
      feasible: [
        TasteRecipeRef(source: .catalog, id: "1"),
        TasteRecipeRef(source: .catalog, id: "2"),
        TasteRecipeRef(source: .catalog, id: "3"),
        TasteRecipeRef(source: .catalog, id: "4"),
      ],
      context: TasteExposureContext(
        kitchenIngredientCount: 6, householdSize: 2, mealContext: "weeknight"))

    try store.logExposure(exposure)
    try store.logExposure(exposure)

    XCTAssertEqual(try store.exposureCount(), 1, "re-logging a render is a no-op")
    XCTAssertEqual(try store.exposure(id: exposure.id), exposure)
  }

  // MARK: - Export and delete

  func testExportAllReturnsEverythingInReplayOrder() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)
    let store = TasteEventStore(db: dbQueue)
    _ = try service.recordCooking(recipeId: 1, rating: 3, servingsConsumed: 2)
    let exposure = TasteExposure(
      id: UUID().uuidString.lowercased(),
      at: Date(timeIntervalSince1970: 1_000_000),
      surface: TasteSurface.homeTonight,
      eater: nil,
      sessionId: nil,
      slate: [TasteExposureItem(recipe: TasteRecipeRef(source: .catalog, id: "1"), position: 1)],
      feasible: [TasteRecipeRef(source: .catalog, id: "1")],
      context: TasteExposureContext(
        kitchenIngredientCount: 3, householdSize: 2, mealContext: nil))
    try store.logExposure(exposure)
    try store.upsertStatement(
      TasteProfileStatement(
        id: UUID().uuidString.lowercased(),
        layer: .restriction,
        featureKind: nil,
        featureKey: nil,
        templateId: "restriction.setup.allergy",
        numerator: nil,
        denominator: nil,
        state: .active,
        mutedUntil: nil,
        pinnedValue: nil,
        lastEvidenceAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_000_000),
        text: "No shellfish."))

    let export = try store.exportAll()
    XCTAssertEqual(export.events.count, 1)
    XCTAssertEqual(export.exposures.count, 1)
    XCTAssertEqual(export.statements.count, 1)

    let json = try store.exportAllJSON()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    let first = try XCTUnwrap(events.first)
    XCTAssertEqual(first["kind"] as? String, "recipe_cooked")
    let at = try XCTUnwrap(first["at"] as? String)
    XCTAssertTrue(at.hasSuffix("Z"), "exported timestamps are UTC: \(at)")
    XCTAssertTrue(at.contains("."), "exported timestamps carry millisecond precision: \(at)")
  }

  func testDeleteAllLeavesNothing() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)
    let store = TasteEventStore(db: dbQueue)
    _ = try service.recordCooking(recipeId: 1, servingsConsumed: 1)
    try store.upsertStatement(
      TasteProfileStatement(
        id: UUID().uuidString.lowercased(),
        layer: .inferred,
        featureKind: .ingredient,
        featureKey: "ingredient:101",
        templateId: "taste.lowrating.hedged",
        numerator: 3,
        denominator: 3,
        state: .active,
        mutedUntil: nil,
        pinnedValue: nil,
        lastEvidenceAt: Date(timeIntervalSince1970: 1_000_000),
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_000_000),
        text: "You seem to go off coriander."))

    try store.deleteAll()

    XCTAssertEqual(try store.eventCount(), 0)
    XCTAssertEqual(try store.exposureCount(), 0)
    XCTAssertEqual(try store.statementCount(), 0)
    XCTAssertEqual(try store.allEvents(), [])
    XCTAssertEqual(try store.allExposures(), [])
    XCTAssertEqual(try store.statements(), [])
    XCTAssertEqual(try store.exportAll().events.count, 0, "export after delete-all is empty")
  }

  // MARK: - Explicit signals

  func testExplicitSignalAPIsWriteTheirEventKinds() throws {
    let dbQueue = try makeMigratedDatabase()
    let service = PersonalizationService(db: dbQueue)
    let store = TasteEventStore(db: dbQueue)

    try service.recordSkip(
      recipeId: 1, exposureId: UUID().uuidString.lowercased(), reason: "made_something_else",
      surface: TasteSurface.homeTonight)
    try service.recordDismissal(recipeId: 1, surface: TasteSurface.homeTonight)
    try service.recordExplicitDislike(
      ingredientId: 101, featureKey: "ingredient:101", surface: TasteSurface.recipeDetail)
    try service.recordIngredientRemoval(recipeId: 1, ingredientId: 101)
    try service.recordSave(recipeId: 1)
    try service.recordUnsave(recipeId: 1)

    // Events at the same timestamp order by id, which is random — assert the signal
    // set and find the dismissal by payload rather than position.
    let all = try store.allEvents()
    XCTAssertEqual(
      Set(all.map(\.kind)),
      [.recipeSkipped, .profileEdited, .ingredientSubstituted, .recipeSaved, .recipeUnsaved],
      "the explicit skip, dismissal, dislike, removal, save, and unsave each write once")
    XCTAssertEqual(all.count, 6)
    let dismissal = try XCTUnwrap(
      all.first {
        if case .skipped(let skippedPayload) = $0.payload { return skippedPayload.reason == "dismissed" }
        return false
      },
      "expected a dismissed skip")
    guard case .skipped(let payload) = dismissal.payload else {
      return XCTFail("expected a skipped payload")
    }
    XCTAssertEqual(payload.reason, "dismissed")
  }
}
