import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// "Buttered Onion Rice" (rcp-000967) needs rice 158 g, plus onion 150 g, butter 30 g and salt
/// as assumed staples. The 2026-10-16 walk at alpha af85600 held rice 180 g and onion 120 g: the
/// Home hero said "Perfect match", the results card "1/1 required" and "Complete match", and the
/// drawer marked onion "Short 30 g".
final class RecipeHeldStapleMatchTests: XCTestCase {
  private let butteredOnionRice = "rcp-000967"

  func testAStapleHeldShortIsNotACompleteMatch() async throws {
    let db = try await makeShippedDatabase()
    let (rice, onion) = try await ids(db)
    try await stock(db, [(rice, 200), (onion, 120)])
    let repo = makeRepository(db)

    let scored = try offered(repo, [rice, onion])
    XCTAssertEqual(scored.matchTier, .nearMatch, "a held, short staple keeps it out of exact")
    XCTAssertFalse(scored.isCompleteMatch)
    XCTAssertEqual(scored.rankingReasons.first, "Short on 1 ingredient")
    XCTAssertFalse(scored.rankingReasons.contains("Complete match"))
    XCTAssertEqual(RecipeMissingIngredientChips.amountNames(for: scored), ["Onion, short 30 g"])
    XCTAssertEqual(
      scored.requiredHadInFull, scored.totalRequired,
      "the staple isn't one of the counted required lines, so \"1/1 required\" stays true")
    XCTAssertTrue(
      scored.catalogLineMarks.contains(.short(grams: 30)), "the drawer says the same thing")
    XCTAssertFalse(
      try repo.findMakeable(with: [rice, onion], profile: .default, limit: 2_000)
        .contains { $0.catalog?.ref.id == butteredOnionRice },
      "the exact tier (Home's \"Perfect match\") does not offer it")
  }

  func testAStapleTheKitchenDoesNotHoldStillNeverBlocksTheMatch() async throws {
    let db = try await makeShippedDatabase()
    let (rice, _) = try await ids(db)
    try await stock(db, [(rice, 200)])

    let scored = try offered(makeRepository(db), [rice])
    XCTAssertEqual(scored.matchTier, .exact)
    XCTAssertTrue(scored.isCompleteMatch)
    XCTAssertTrue(scored.catalogLineMarks.contains(.usuallyOnHand))
  }

  func testAStapleHeldInFullOrOnlyAsAnEstimateStaysComplete() async throws {
    let db = try await makeShippedDatabase()
    let (rice, onion) = try await ids(db)
    try await stock(db, [(rice, 200), (onion, 150)])
    let repo = makeRepository(db)
    let full = try offered(repo, [rice, onion])
    XCTAssertEqual(full.matchTier, .exact)

    try await db.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET quantity_is_estimate = 1 WHERE ingredient_id = ?",
        arguments: [onion])
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = 100 WHERE ingredient_id = ?",
        arguments: [onion])
    }
    let estimated = try offered(repo, [rice, onion])
    XCTAssertEqual(estimated.matchTier, .exact, "an estimate proves no shortfall")
    XCTAssertTrue(estimated.catalogLineMarks.contains(.checkAmount))
  }

  /// Moving to the near tier must not reorder anything by itself: the ranking score of the
  /// recipe is the same whether its held staple is short or covered.
  func testRankingScoreIsUnchangedByTheStapleShortfall() async throws {
    let db = try await makeShippedDatabase()
    let (rice, onion) = try await ids(db)
    try await stock(db, [(rice, 200), (onion, 150)])
    let repo = makeRepository(db)
    let covered = try offered(repo, [rice, onion])

    try await db.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = 120 WHERE ingredient_id = ?",
        arguments: [onion])
    }
    let short = try offered(repo, [rice, onion])
    XCTAssertEqual(short.rankingScore, covered.rankingScore)
    XCTAssertEqual(short.matchedOptional, covered.matchedOptional)
  }

  // MARK: - Helpers

  private func makeShippedDatabase() async throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    guard RecipeBundleV2Loader.bundleV2URL(in: .main) != nil else {
      throw XCTSkip("shipped bundle missing from the app bundle")
    }
    try await AppDatabase(dbQueue: db).warmBundledContentIfNeeded()
    return db
  }

  private func makeRepository(_ db: DatabaseQueue) -> RecipeRepository {
    let nutrition = NutritionService(db: db)
    return RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db)
    )
  }

  /// An app ingredient the bundle bridges each line key to.
  private func ids(_ db: DatabaseQueue) async throws -> (rice: Int64, onion: Int64) {
    let bridge = try await db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge
          WHERE ingredient_key IN ('rice', 'onion')
          """
      ).reduce(into: [String: [Int64]]()) { $0[$1["ingredient_key"], default: []].append($1["ingredient_id"]) }
    }
    // A line can bridge to several ingredients; the pantry holds one of each, so one lot is
    // the line's whole stock.
    return (try XCTUnwrap(bridge["rice"]?.min()), try XCTUnwrap(bridge["onion"]?.min()))
  }

  private func stock(_ db: DatabaseQueue, _ lots: [(Int64, Double)]) async throws {
    try await db.write { db in
      for (id, grams) in lots {
        try db.execute(
          sql: """
            INSERT INTO inventory_lots
              (ingredient_id, quantity_grams, remaining_grams, quantity_is_estimate)
            VALUES (?, ?, ?, 0)
            """,
          arguments: [id, grams, grams])
      }
    }
  }

  private func offered(_ repo: RecipeRepository, _ pantry: Set<Int64>) throws -> ScoredRecipe {
    let all =
      try repo.findMakeable(with: pantry, profile: .default, limit: 2_000)
      + repo.findNearMatch(with: pantry, profile: .default, maxMissingRequired: 2, limit: 2_000)
    return try XCTUnwrap(
      all.first { $0.catalog?.ref.id == butteredOnionRice }, "Buttered Onion Rice not offered")
  }
}
