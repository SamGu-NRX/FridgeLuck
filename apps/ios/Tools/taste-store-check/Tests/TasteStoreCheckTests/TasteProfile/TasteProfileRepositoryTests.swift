import XCTest
import GRDB

@testable import FLFeatureLogic
#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
// Portable Linux check (Tools/taste-store-check): the same sources live in the
// TasteStoreCheck mirror module instead of the app target.
@testable import TasteStoreCheck
#endif

/// Repository behaviour over the real schema: evidence aggregation from the event log,
/// persisted statement state, corrections, and the health-profile reset guarantee.
/// Statement text and thresholds are the builder's tests; these pin what the repository
/// persists and rebuilds.
final class TasteProfileRepositoryTests: XCTestCase {
  private var dbQueue: DatabaseQueue!
  private var store: TasteEventStore!
  private var repo: TasteProfileRepository!
  private let now = Date(timeIntervalSince1970: 1_792_000_000)

  override func setUpWithError() throws {
    dbQueue = try DatabaseQueue()
    #if canImport(FridgeLuck)
    try DatabaseMigrations.migrate(dbQueue)
    #else
    // Portable check (Tools/taste-store-check): the full migration chain lives in the
    // iOS target, so build the core tables this feature reads and run the taste
    // subsystem migrations; the complete chain is covered by macOS CI.
    try Self.makePortableSchema(dbQueue)
    var migrator = DatabaseMigrator()
    TasteMigrations.register(in: &migrator)
    try migrator.migrate(dbQueue)
    #endif
    store = TasteEventStore(db: dbQueue)
    repo = TasteProfileRepository(dbQueue: dbQueue, store: store)
  }

  #if !canImport(FridgeLuck)
  /// Core tables the taste profile reads, matching their shipped schema in
  /// Platform/Persistence/Database/Migrations.swift.
  private static func makePortableSchema(_ dbQueue: DatabaseQueue) throws {
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
      try db.create(table: "health_profile") { t in
        t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
        t.column("goal", .text).defaults(to: "general")
        t.column("daily_calories", .integer)
        t.column("protein_pct", .double).defaults(to: 0.25)
        t.column("carbs_pct", .double).defaults(to: 0.45)
        t.column("fat_pct", .double).defaults(to: 0.30)
        t.column("dietary_restrictions", .text).defaults(to: "[]")
        t.column("allergen_ingredient_ids", .text).defaults(to: "[]")
        t.column("updated_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
        t.column("display_name", .text).notNull().defaults(to: "")
        t.column("age", .integer)
      }
    }
  }
  #endif

  private func day(_ days: Double) -> Date {
    now.addingTimeInterval(-days * 86_400)
  }

  // MARK: - Seed data

  private func insertIngredients() throws {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (10, 'Coriander', 23, 0.9, 0.9, 0.4), (11, 'Tofu', 76, 8, 1.9, 4.8)
          """)
    }
  }

  private func insertRecipe(_ id: Int64, ingredients: [Int64]) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (?, ?, 10, 1, 'Cook it.')
          """,
        arguments: [id, "Recipe \(id)"])
      for ingredientId in ingredients {
        try db.execute(
          sql: """
            INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
            VALUES (?, ?, 1, 100, '100 g')
            """,
          arguments: [id, ingredientId])
      }
    }
  }

  private func insertHealthProfile(allergens: [Int64], diets: [String]) throws {
    let allergensJSON = String(
      decoding: try JSONEncoder().encode(allergens), as: UTF8.self)
    let dietsJSON = String(decoding: try JSONEncoder().encode(diets), as: UTF8.self)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO health_profile
            (id, dietary_restrictions, allergen_ingredient_ids) VALUES (1, ?, ?)
          """,
        arguments: [dietsJSON, allergensJSON])
    }
  }

  private func appendCook(
    recipeId: Int64, rating: Int?, at: Date, cookEventId: String
  ) throws {
    try store.append(
      TasteEventRecord(
        id: cookEventId,
        at: at,
        recipe: TasteRecipeRef(id: String(recipeId), revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.cookComplete,
        payload: .cooked(
          TasteCookedPayload(
            cookSessionId: nil, exposureId: nil, rating: rating, servings: 2,
            slatePosition: nil, wouldMakeAgain: nil)),
        cookEventId: cookEventId))
  }

  private func appendRated(cookEventId: String, rating: Int, at: Date) throws {
    try store.append(
      TasteEventRecord(
        at: at,
        recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.tasteProfile,
        payload: .rated(TasteRatedPayload(cookEventId: cookEventId, rating: rating)),
        cookEventId: cookEventId))
  }

  private func appendSubstitution(
    ingredientId: Int64, cookEventId: String, motivation: TasteSwapMotivation, at: Date
  ) throws {
    try store.append(
      TasteEventRecord(
        at: at,
        recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        ingredient: ingredientId,
        surface: TasteSurface.cookIngredients,
        payload: .substituted(
          TasteSubstitutionPayload(
            cookEventId: cookEventId, motivation: motivation, ratio: nil,
            substituteIngredientId: nil)),
        cookEventId: cookEventId))
  }

  private func statementRow(id: String) throws -> TasteProfileStatement? {
    try store.statement(id: id)
  }

  private func inferredId(_ ingredientId: Int64, _ template: String = "taste.lowrating")
    -> String
  {
    TasteStatementIdentity.statementId(
      featureKey: "ingredient:\(ingredientId)", templateId: template)
  }

  private func pinId(_ ingredientId: Int64) -> String {
    TasteStatementIdentity.statementId(
      featureKey: "ingredient:\(ingredientId)", templateId: "pinned.dont_ask_again")
  }

  /// Three coriander cooks rated 2, 1, 1 — the golden fixture's statement case.
  private func seedCorianderEvidence() throws {
    try insertIngredients()
    try insertRecipe(1, ingredients: [10])
    try appendCook(recipeId: 1, rating: 2, at: day(9), cookEventId: "cook-1")
    try appendCook(recipeId: 1, rating: 1, at: day(8), cookEventId: "cook-2")
    try appendCook(recipeId: 1, rating: 1, at: day(7), cookEventId: "cook-3")
  }

  // MARK: - Evidence aggregation

  func testCorianderEvidenceProducesPersistedStatement() async throws {
    try seedCorianderEvidence()
    let page = try await repo.recomputeProfile(now: now)

    let inferred = page.statements(layer: .inferred)
    XCTAssertEqual(inferred.count, 1)
    XCTAssertEqual(inferred[0].featureKey, "ingredient:10")
    XCTAssertEqual(inferred[0].numerator, 3)
    XCTAssertEqual(inferred[0].denominator, 3)
    XCTAssertEqual(
      inferred[0].text,
      "You seem to go off Coriander: the last 3 recipes you cooked with it were rated 2 stars or below."
    )
    // The statement row is persisted with the evidence counts and its own id.
    let row = try statementRow(id: inferredId(10))
    XCTAssertEqual(row?.state, .active)
    XCTAssertEqual(row?.numerator, 3)
    XCTAssertEqual(row?.denominator, 3)
  }

  /// A rating arriving after the cook merges into the cook's transaction window via
  /// cookEventId; the display threshold needs a denominator of at least 3.
  func testRatingGivenAfterTheCookMergesIntoTheCookTransaction() async throws {
    try insertIngredients()
    try insertRecipe(1, ingredients: [10])
    try appendCook(recipeId: 1, rating: 2, at: day(9), cookEventId: "cook-1")
    try appendCook(recipeId: 1, rating: 1, at: day(8), cookEventId: "cook-2")
    try appendCook(recipeId: 1, rating: nil, at: day(7), cookEventId: "cook-3")
    try appendRated(cookEventId: "cook-3", rating: 1, at: day(3))
    let page = try await repo.recomputeProfile(now: now)
    let inferred = page.statements(layer: .inferred)
    XCTAssertEqual(inferred.count, 1)
    XCTAssertEqual(inferred[0].featureKey, "ingredient:10")
    XCTAssertEqual(inferred[0].numerator, 3)
    XCTAssertEqual(inferred[0].denominator, 3)
  }

  func testExposureOnlyEventsProduceNoStatements() async throws {
    try insertIngredients()
    try insertRecipe(1, ingredients: [10])
    // Views, opens, saves and skips only — no cook, no rating, no substitution.
    try store.append(
      TasteEventRecord(
        at: day(1), recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.homeTonight,
        payload: .viewed(TasteSlateInteractionPayload(exposureId: nil, slatePosition: 0))))
    try store.append(
      TasteEventRecord(
        at: day(1), recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.recipeDetail,
        payload: .opened(TasteSlateInteractionPayload(exposureId: nil, slatePosition: 0))))
    try store.append(
      TasteEventRecord(
        at: day(1), recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.recipeDetail, payload: .saved(TasteSavedPayload(exposureId: nil))))
    try store.append(
      TasteEventRecord(
        at: day(1), recipe: TasteRecipeRef(id: "1", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.homeTonight,
        payload: .skipped(TasteSkippedPayload(exposureId: nil, reason: "too_much_work"))))
    let page = try await repo.recomputeProfile(now: now)
    XCTAssertTrue(page.statements(layer: .inferred).isEmpty)
    XCTAssertTrue(try store.statements().filter { $0.layer == .inferred }.isEmpty)
  }

  func testSubstitutionClaimCountsDeduplicatedCooks() async throws {
    try insertIngredients()
    try insertRecipe(1, ingredients: [11])
    try appendCook(recipeId: 1, rating: 3, at: day(5), cookEventId: "cook-1")
    try appendCook(recipeId: 1, rating: 3, at: day(4), cookEventId: "cook-2")
    try appendCook(recipeId: 1, rating: 3, at: day(3), cookEventId: "cook-3")
    // Two cooks swapped tofu out; the third substitution is the same cook twice.
    try appendSubstitution(ingredientId: 11, cookEventId: "cook-1", motivation: .preferred, at: day(5))
    try appendSubstitution(ingredientId: 11, cookEventId: "cook-2", motivation: .preferred, at: day(4))
    try appendSubstitution(ingredientId: 11, cookEventId: "cook-2", motivation: .noneAvailable, at: day(3))
    let page = try await repo.recomputeProfile(now: now)

    let substituted = page.statements(layer: .inferred).filter {
      $0.featureKey == "ingredient:11"
    }
    XCTAssertEqual(substituted.count, 1)
    XCTAssertEqual(substituted[0].numerator, 2, "deduplicated per cook transaction")
    XCTAssertEqual(substituted[0].denominator, 3)
    XCTAssertTrue(substituted[0].text.contains("You avoid Tofu"))
  }

  func testSubstitutionsInRecommendedRecipesNeverCount() async throws {
    try insertIngredients()
    try insertRecipe(1, ingredients: [11])
    try appendCook(recipeId: 1, rating: 3, at: day(5), cookEventId: "cook-1")
    try appendCook(recipeId: 1, rating: 3, at: day(4), cookEventId: "cook-2")
    try appendCook(recipeId: 1, rating: 3, at: day(3), cookEventId: "cook-3")
    try appendSubstitution(
      ingredientId: 11, cookEventId: "cook-1", motivation: .recipeRecommended, at: day(5))
    let page = try await repo.recomputeProfile(now: now)
    XCTAssertTrue(page.statements(layer: .inferred).isEmpty)
  }

  // MARK: - Corrections

  func testThisIsWrongRemovesTheStatementAndItDoesNotReturn() async throws {
    try seedCorianderEvidence()
    _ = try await repo.recomputeProfile(now: now)
    let id = inferredId(10)
    try await repo.markWrong(statementId: id, now: now)

    // Row kept, rejected.
    XCTAssertEqual(try statementRow(id: id)?.state, .rejected)

    // More of the same evidence cannot re-learn it.
    try appendCook(recipeId: 1, rating: 1, at: day(6), cookEventId: "cook-4")
    let page = try await repo.recomputeProfile(now: now)
    XCTAssertEqual(page.statements(layer: .inferred).map(\.state), [.rejected])
    XCTAssertTrue(page.statements(layer: .inferred).allSatisfy { $0.id == id })

    // The correction is logged as a first-class event.
    XCTAssertEqual(try store.allEvents().filter { $0.kind == .correctionApplied }.count, 1)
  }

  func testDontAskAgainBehavesDifferentlyFromThisIsWrong() async throws {
    try seedCorianderEvidence()
    _ = try await repo.recomputeProfile(now: now)
    let id = inferredId(10)
    try await repo.markDontAskAgain(statementId: id, mutedUntil: nil, now: now)

    // The statement is muted for 90 days and a pin with rank effect is recorded.
    let muted = try statementRow(id: id)
    XCTAssertEqual(muted?.state, .muted)
    XCTAssertEqual(muted?.mutedUntil, now.addingTimeInterval(90 * 86_400))
    let pin = try statementRow(id: pinId(10))
    XCTAssertEqual(pin?.layer, .pinned)
    XCTAssertEqual(pin?.pinnedValue, -6.0)

    // Recompute within the mute: the statement stays muted, the pin survives.
    _ = try await repo.recomputeProfile(now: now.addingTimeInterval(86_400))
    XCTAssertEqual(try statementRow(id: id)?.state, .muted)
    XCTAssertEqual(try statementRow(id: pinId(10))?.state, .muted)

    // Past the mute the same evidence brings it back.
    let page = try await repo.recomputeProfile(now: now.addingTimeInterval(91 * 86_400))
    XCTAssertEqual(page.statements(layer: .inferred).first?.state, .active)
  }

  func testReopenRevivesARejectedStatement() async throws {
    try seedCorianderEvidence()
    _ = try await repo.recomputeProfile(now: now)
    let id = inferredId(10)
    try await repo.markWrong(statementId: id, now: now)
    try await repo.reopen(statementId: id, now: now)

    let page = try await repo.recomputeProfile(now: now)
    XCTAssertEqual(page.statements(layer: .inferred)[0].state, .active)
    XCTAssertEqual(page.statements(layer: .inferred)[0].numerator, 3)
  }

  func testReopeningThePinUnmutesAndRemovesThePin() async throws {
    try seedCorianderEvidence()
    _ = try await repo.recomputeProfile(now: now)
    try await repo.markDontAskAgain(statementId: inferredId(10), mutedUntil: nil, now: now)
    try await repo.reopen(statementId: pinId(10), now: now)

    let page = try await repo.recomputeProfile(now: now)
    XCTAssertEqual(page.statements(layer: .inferred)[0].state, .active)
    XCTAssertNil(try statementRow(id: pinId(10)), "the pin row is gone")
  }

  // MARK: - Reset guarantee

  func testRestrictionsSurviveAFullTasteLogReset() async throws {
    try seedCorianderEvidence()
    try insertHealthProfile(allergens: [10], diets: ["vegan"])
    _ = try await repo.recomputeProfile(now: now)

    // The reset the taste settings screen offers: everything machine-learned is gone.
    try store.deleteAll()
    try await repo.recomputeProfile(now: now)
    let after = try await repo.loadProfile(now: now)

    XCTAssertTrue(after.statements(layer: .inferred).isEmpty, "learned statements are gone")
    let restrictions = after.statements(layer: .restriction)
    XCTAssertEqual(restrictions.count, 2, "restriction sentences come back from the profile")
    XCTAssertEqual(
      Set(restrictions.map(\.text)),
      [
        "No Coriander. Set at setup, edited in setup only.",
        "No vegan. Set at setup, edited in setup only.",
      ])
  }

  func testRestrictionsRenderFromHealthProfileBeforeAnyRecompute() async throws {
    try insertIngredients()
    try insertHealthProfile(allergens: [11], diets: [])
    // No recompute has ever run: the read path still shows the restriction.
    let page = try await repo.loadProfile(now: now)
    XCTAssertEqual(
      page.statements(layer: .restriction).map(\.text),
      ["No Tofu. Set at setup, edited in setup only."])
  }
}
