import FLFeatureLogic
import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// The taste event log: idempotent appends, transaction coupling with the meal log,
/// queries, and the export/delete-everything contract
/// (docs/spec/taste/SPEC.md §5, contracts in docs/spec/taste/contracts/).
final class TasteEventStoreTests: XCTestCase {
  // MARK: - Helpers

  private func makeStore() throws -> TasteEventStore {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return TasteEventStore(db: db)
  }

  private func makeMigratedPersonalizationDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
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
    return dbQueue
  }

  private func cookedEvent(
    id: String = UUID().uuidString.lowercased(),
    at: Date = Date(timeIntervalSince1970: 1_000_000),
    recipeId: String = "1",
    rating: Int? = 2
  ) -> TasteEventRecord {
    TasteEventRecord(
      id: id,
      at: at,
      recipe: TasteRecipeRef(id: recipeId, revision: 1, source: TasteRecipeSource.catalog.rawValue),
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

    let first = try store.append(event)
    let second = try store.append(event)

    XCTAssertTrue(first)
    XCTAssertFalse(second, "replaying a stable event id must not insert a second row")
    XCTAssertEqual(try store.eventCount(), 1)
    XCTAssertTrue(try store.containsEvent(id: event.id))
  }

  func testEventsRoundTripThroughStorage() throws {
    let store = try makeStore()
    let event = cookedEvent()

    try store.append(event)

    let stored = try store.events(recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue))
    XCTAssertEqual(stored, [event])
    XCTAssertEqual(stored.first?.kind, .recipeCooked)
  }

  // MARK: - Meal log and events commit or roll back together

  func testMealLogAndItsTasteEventsCommitTogether() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
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
    let dbQueue = try makeMigratedPersonalizationDatabase()
    let service = PersonalizationService(db: dbQueue)
    // A swap for an ingredient that is not required of the recipe makes the log throw.
    let bogusSwap = IngredientSwap(
      originalIngredientId: 99, substituteIngredientId: 11, ratio: 1.0)

    XCTAssertThrowsError(
      try service.recordCooking(recipeId: 1, servingsConsumed: 1, swaps: [bogusSwap])
    )

    try dbQueue.read { db in
      let historyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cooking_history")
      XCTAssertEqual(historyCount, 0, "the meal log rolled back")
      let swapCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM cooking_history_swaps")
      XCTAssertEqual(swapCount, 0)
    }
    let store = TasteEventStore(db: dbQueue)
    XCTAssertEqual(
      try store.eventCount(), 0, "the cook's taste events rolled back with the meal log")
  }

  func testSwapsWriteSubstitutionEventsInTheSameTransaction() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
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
    // The substitution merges into the cook's transaction window.
    let cookEvents = try store.allEvents().filter { $0.kind == .recipeCooked }
    XCTAssertEqual(payload.cookEventId, cookEvents.first?.cookEventId)
  }

  func testRateLastCookingWritesARatedEventLinkedToTheCook() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
    let service = PersonalizationService(db: dbQueue)

    _ = try service.recordCooking(recipeId: 1, servingsConsumed: 1)
    try service.rateLastCooking(recipeId: 1, rating: 4)

    let store = TasteEventStore(db: dbQueue)
    let events = try store.allEvents()
    // Cook and rate can tie on the stored timestamp; replay order then falls to the id
    // tiebreak (SPEC §5), so assert the kinds present and pick the events by kind.
    XCTAssertEqual(Set(events.map(\.kind)), [.recipeCooked, .recipeRated])
    let ratedPayloads = events.compactMap { event -> TasteRatedPayload? in
      if case .rated(let rated) = event.payload { return rated }
      return nil
    }
    guard let rated = ratedPayloads.first else {
      return XCTFail("expected a recipe_rated event")
    }
    XCTAssertEqual(rated.rating, 4)
    let cookEvent = events.first { $0.kind == .recipeCooked }
    XCTAssertEqual(
      rated.cookEventId, cookEvent?.cookEventId,
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
      TasteEventRecord(
        id: UUID().uuidString.lowercased(),
        at: middle,
        recipe: TasteRecipeRef(id: "2", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        ingredient: 101,
        surface: TasteSurface.cookIngredients,
        payload: .substituted(
          TasteSubstitutionPayload(
            cookEventId: nil, motivation: .preferred, ratio: 1.0,
            substituteIngredientId: 105))))
    try store.append(cookedEvent(id: UUID().uuidString.lowercased(), at: late, recipeId: "1"))

    XCTAssertEqual(try store.events(recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue)).count, 2)
    XCTAssertEqual(
      try store.events(recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.user.rawValue)).count, 0,
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
    let exposure = TasteExposureRecord(
      id: UUID().uuidString.lowercased(),
      at: Date(timeIntervalSince1970: 1_000_000),
      surface: TasteSurface.homeTonight,
      eater: nil,
      sessionId: "sess-1",
      slate: [
        TasteSlateItem(position: 1, recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue)),
        TasteSlateItem(position: 2, recipe: TasteRecipeRef(id: "2", revision: 1, source: TasteRecipeSource.catalog.rawValue)),
      ],
      feasible: [
        TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        TasteRecipeRef(id: "2", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        TasteRecipeRef(id: "3", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        TasteRecipeRef(id: "4", revision: 1, source: TasteRecipeSource.catalog.rawValue),
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
    let dbQueue = try makeMigratedPersonalizationDatabase()
    let service = PersonalizationService(db: dbQueue)
    let store = TasteEventStore(db: dbQueue)
    _ = try service.recordCooking(recipeId: 1, rating: 3, servingsConsumed: 2)
    let exposure = TasteExposureRecord(
      id: UUID().uuidString.lowercased(),
      at: Date(timeIntervalSince1970: 1_000_000),
      surface: TasteSurface.homeTonight,
      eater: nil,
      sessionId: nil,
      slate: [TasteSlateItem(position: 1, recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue))],
      feasible: [TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue)],
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
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: json) as? [String: Any])
    let events = try XCTUnwrap(object["events"] as? [[String: Any]])
    let first = try XCTUnwrap(events.first)
    XCTAssertEqual(first["kind"] as? String, "recipe_cooked")
    // Contract timestamp shape: ISO-8601 UTC with millisecond precision.
    let at = try XCTUnwrap(first["at"] as? String)
    XCTAssertTrue(at.hasSuffix("Z"), "exported timestamps are UTC: \(at)")
    XCTAssertTrue(at.contains("."), "exported timestamps carry millisecond precision: \(at)")
  }

  func testDeleteAllLeavesNothing() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
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
    XCTAssertEqual(
      try store.exportAll().events.count, 0, "export after delete-all is empty")
  }

  // MARK: - Explicit signals

  func testExplicitSignalAPIsWriteTheirEventKinds() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
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

    // Same-millisecond signals tie on the (at, id) order with random ids, so the kind
    // multiset is the contract here, not the positional order.
    let kinds = try store.allEvents().map(\.kind)
    let expectedKinds: [TasteEventKind] = [
      .recipeSkipped, .recipeSkipped, .profileEdited, .ingredientSubstituted, .recipeSaved,
      .recipeUnsaved,
    ]
    XCTAssertEqual(kinds.map(\.rawValue).sorted(), expectedKinds.map(\.rawValue).sorted())

    let skipReasons = try store.allEvents().compactMap { event -> String? in
      if case .skipped(let dismissal) = event.payload { return dismissal.reason }
      return nil
    }
    XCTAssertEqual(Set(skipReasons), ["made_something_else", "dismissed"])
  }

  // MARK: - Engine replay parity and identity guards

  /// Direct-replay parity for the trunk seam: the baseline is built from the writer
  /// shapes the meal log uses (three 5-star cooked events, each anchoring its own cook
  /// transaction, plus one rated event linked to the last cook), so a store bug that
  /// corrupts kind, recipe identity, or payload on the way in or out changes one side of
  /// the comparison instead of cloning itself into both.
  func testEngineReplayOfStoreRoundTripMatchesADirectReplayOfTheWriterShapes() throws {
    let store = try makeStore()
    let ref = TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue)
    let direct: [TasteEventRecord] = (0..<3).map { index in
      TasteEventRecord(
        id: "trunk-writer-cook-\(index)",
        at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
        recipe: ref,
        surface: TasteSurface.cookComplete,
        payload: .cooked(
          TasteCookedPayload(
            cookSessionId: nil, exposureId: nil, rating: 5, servings: 2,
            slatePosition: nil, wouldMakeAgain: nil)),
        cookEventId: "trunk-writer-cook-\(index)")
    } + [
      TasteEventRecord(
        id: "trunk-writer-rate",
        at: Date(timeIntervalSince1970: 1_000_000 + 240),
        recipe: ref,
        surface: TasteSurface.cookComplete,
        payload: .rated(TasteRatedPayload(cookEventId: "trunk-writer-cook-2", rating: 5)),
        cookEventId: "trunk-writer-cook-2"),
    ]

    var engineDirect = TasteResidualEngine(
      featureKeysByRecipe: ["1": ["ingredient:10"]], nameOf: ["ingredient:10": "Chicken"])
    engineDirect.ingest(events: direct.map(\.event), exposures: [])

    for record in direct {
      XCTAssertTrue(try store.append(record))
    }
    var engineFromStore = TasteResidualEngine(
      featureKeysByRecipe: ["1": ["ingredient:10"]], nameOf: ["ingredient:10": "Chicken"])
    engineFromStore.ingest(events: try store.allEvents().map(\.event), exposures: [])

    let evalAt = TasteTimestamp.string(from: Date(timeIntervalSince1970: 1_000_000 + 86_400))
    XCTAssertEqual(
      engineFromStore.contributions(evalAt: evalAt),
      engineDirect.contributions(evalAt: evalAt),
      "store round-trip must not change what the engine learns")
    XCTAssertGreaterThan(
      engineFromStore.contributions(evalAt: evalAt)["ingredient:10"] ?? 0, 0)
  }

  /// The store keys events on (source, id); a ref without a source would bind
  /// `recipe_source = NULL` in SQL and silently match nothing.
  func testEventsForARefWithoutASourceThrowsInsteadOfMatchingNothing() throws {
    let store = try makeStore()
    XCTAssertThrowsError(
      try store.events(recipe: TasteRecipeRef(id: "1", revision: 1, source: nil)))
  }

  func testLatestCookEventIdForARefWithoutASourceThrowsInsteadOfMatchingNothing() throws {
    let dbQueue = try makeMigratedPersonalizationDatabase()
    let store = TasteEventStore(db: dbQueue)
    try dbQueue.read { db in
      XCTAssertThrowsError(
        try store.latestCookEventId(
          for: TasteRecipeRef(id: "1", revision: 1, source: nil), in: db))
    }
  }
}
