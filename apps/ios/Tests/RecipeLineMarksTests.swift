import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// Result cards and the recipe preview must say the same thing about each line, with real
/// names (2026-10-16 walk at alpha a32bfe3, kitchen of egg 50 g, rice 180 g and about 30 g of
/// soy sauce estimated from a photo):
/// - the best match card listed "Green Onion, Unknown, Unknown" under "missing 1", while the
///   preview marked only green onion missing;
/// - sesame oil and butter, not in the kitchen, showed green checks;
/// - soy sauce, 32 g needed and about 30 g estimated, showed a plain check.
final class RecipeLineMarksTests: XCTestCase {
  /// "Soft-Scrambled Egg Rice Bowl with Soy and Scallion": egg 200 g, rice 350 g, green onion
  /// 18 g; soy sauce 32 g, sesame oil 4.5 g and butter 14 g are assumed staples.
  private let eggRiceBowl = "rcp-000261"
  private let egg: Int64 = 1
  private let rice: Int64 = 2
  private let soySauce: Int64 = 3

  func testCardSummaryAndPreviewAgreeForTheWalkedKitchen() async throws {
    let db = try await makeShippedDatabase()
    try stock(db, [(egg, 50, false), (rice, 180, false), (soySauce, 30, true)])
    let repo = makeRepository(db)

    let scored = try XCTUnwrap(
      try repo.findNearMatch(
        with: [egg, rice, soySauce], profile: .default, maxMissingRequired: 2, limit: 2_000
      ).first { $0.catalog?.ref.id == eggRiceBowl })

    let chips = RecipeMissingIngredientChips.names(for: scored)
    XCTAssertEqual(chips, ["Green onion"])
    XCTAssertEqual(scored.missingRequiredCount, 1)
    XCTAssertEqual(scored.rankingReasons.first, "Almost there (missing 1)")
    XCTAssertEqual(
      RecipeMissingIngredientChips.amountNames(for: scored),
      ["Egg, short 150 g", "Rice, short 170 g"])

    let marks = try previewMarks(repo, scored)
    XCTAssertEqual(
      marks.filter { $0.value == .missing }.count, chips.count,
      "the preview marks as many lines missing as the card names")
    XCTAssertEqual(marks["Green onion"], .missing)
    XCTAssertEqual(marks["Egg"], .short(grams: 150))
    XCTAssertEqual(marks["Rice"], .short(grams: 170))
    XCTAssertEqual(marks["Soy sauce"], .checkAmount, "an estimate below the need is unproven")
    XCTAssertEqual(marks["Sesame oil"], .usuallyOnHand)
    XCTAssertEqual(marks["Butter"], .usuallyOnHand)
  }

  /// Every line of every shipped recipe has a name on result cards and in the preview, and each
  /// card names as many missing lines as it counts. The pantry holds one ingredient, so nearly
  /// every line of every recipe is missing and gets named.
  func testNoShippedIngredientIsNamedUnknown() async throws {
    let db = try await makeShippedDatabase()
    try stock(db, [(egg, 10, false)])
    let repo = makeRepository(db)

    let catalog = try repo.catalogMatches(
      with: [egg], profile: .default, minMissingRequired: 0, maxMissingRequired: 1_000,
      matchTier: .nearMatch, limit: 10_000)
    let legacy = try repo.findNearMatchLegacy(
      with: [egg], profile: .default, maxMissingRequired: 1_000, limit: 10_000)
    XCTAssertGreaterThan(catalog.count, 700, "every catalog original is judged")
    XCTAssertFalse(legacy.isEmpty)

    for scored in catalog + legacy {
      let chips = RecipeMissingIngredientChips.names(for: scored)
      XCTAssertEqual(chips.count, scored.missingRequiredCount, scored.recipe.title)
      let amounts = RecipeMissingIngredientChips.amountNames(for: scored)
      XCTAssertEqual(amounts.count, scored.insufficientRequiredLines.count, scored.recipe.title)
      for name in chips + amounts {
        XCTAssertFalse(isPlaceholder(name), "\(scored.recipe.title): \"\(name)\"")
      }
    }

    for scored in catalog {
      let packet = try XCTUnwrap(try repo.catalogCookPacket(for: scored))
      let rows = RecipePreviewIngredientRows.catalog(
        packet,
        ingredientsByID: try repo.ingredients(
          withIDs: Set(packet.lines.compactMap(\.bridgedIngredientId))))
      XCTAssertEqual(rows.count, packet.lines.count, "every line shows, linked or not")
      XCTAssertEqual(rows.count, scored.catalogLineMarks.count, scored.recipe.title)
      for row in rows {
        XCTAssertFalse(isPlaceholder(row.name), "\(scored.recipe.title): \"\(row.name)\"")
      }
      XCTAssertEqual(
        rows.filter { $0.mark(in: scored, isSubstituted: false) == .missing }.count,
        scored.missingRequiredCount, scored.recipe.title)
    }
  }

  // MARK: - Mark rules

  func testAssumedStapleTheKitchenLacksIsUsuallyOnHand() {
    XCTAssertEqual(
      RecipeIngredientMark.line(isRequired: true, isAssumedStaple: true, supply: .missing),
      .usuallyOnHand)
    XCTAssertEqual(
      RecipeIngredientMark.line(isRequired: true, isAssumedStaple: false, supply: .missing),
      .missing)
  }

  func testAssumedStapleKeepsItsAmountMarks() {
    for (supply, mark) in [
      (IngredientSupply.checkAmount, RecipeIngredientMark.checkAmount),
      (.short(grams: 4), .short(grams: 4)),
      (.have, .have),
    ] {
      XCTAssertEqual(
        RecipeIngredientMark.line(isRequired: true, isAssumedStaple: true, supply: supply), mark)
    }
  }

  // MARK: - Helpers

  private func isPlaceholder(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.caseInsensitiveCompare("Unknown") == .orderedSame
  }

  private func previewMarks(
    _ repo: RecipeRepository, _ scored: ScoredRecipe
  ) throws -> [String: RecipeIngredientMark] {
    let packet = try XCTUnwrap(try repo.catalogCookPacket(for: scored))
    let rows = RecipePreviewIngredientRows.catalog(
      packet,
      ingredientsByID: try repo.ingredients(
        withIDs: Set(packet.lines.compactMap(\.bridgedIngredientId))))
    return Dictionary(
      rows.map { ($0.name, $0.mark(in: scored, isSubstituted: false)) },
      uniquingKeysWith: { first, _ in first })
  }

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

  private func stock(_ db: DatabaseQueue, _ lots: [(Int64, Double, Bool)]) throws {
    try db.write { db in
      for (id, grams, isEstimate) in lots {
        try db.execute(
          sql: """
            INSERT INTO inventory_lots
              (ingredient_id, quantity_grams, remaining_grams, quantity_is_estimate)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [id, grams, grams, isEstimate])
      }
    }
  }
}
