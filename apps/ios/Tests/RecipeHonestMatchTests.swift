import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// What a household is offered must be a recipe FridgeLuck may ship, and "Complete match" must
/// mean the kitchen holds enough of every required line (2026-10-16 walk at alpha 9e4a3af:
/// the quarantined "Classic Egg Fried Rice" was the Home hero, called complete with 50 g of
/// the 100 g of egg and 180 g of the 316 g of rice it needs).
final class RecipeHonestMatchTests: XCTestCase {
  // MARK: - Quarantine over the shipped data

  /// Every quarantine entry the app reads either names a shipped legacy row by id and title,
  /// or names no shipped recipe at all, so the title match below covers the whole list.
  func testShippedQuarantineListMapsOntoTheShippedRecipes() async throws {
    let db = try await makeShippedDatabase()
    let entries = try RecipeQuarantine.load(from: .main)
    XCTAssertFalse(entries.isEmpty, "quarantine.jsonl shipped empty")

    for entry in entries {
      let title = entry.recipe.title.trimmingCharacters(in: .whitespaces).lowercased()
      if let legacyID = entry.legacyRecipeID {
        let shippedTitle = try await db.read { db in
          try String.fetchOne(
            db, sql: "SELECT LOWER(TRIM(title)) FROM recipes WHERE id = ? AND source = 'bundled'",
            arguments: [legacyID])
        }
        XCTAssertEqual(shippedTitle, title, "\(entry.id) does not name legacy recipe \(legacyID)")
      } else {
        let shipped = try await db.read { db in
          try Int.fetchOne(
            db,
            sql: """
              SELECT (SELECT COUNT(*) FROM recipes WHERE LOWER(TRIM(title)) = ?)
                   + (SELECT COUNT(*) FROM recipes_catalog
                      WHERE LOWER(TRIM(title)) = ? AND rights_status = 'original')
              """,
            arguments: [title, title]) ?? 0
        }
        XCTAssertEqual(shipped, 0, "\(entry.id) has no legacy id but ships anyway")
      }
    }
  }

  /// A kitchen holding every ingredient the bundle knows is offered no quarantined recipe by
  /// recommendations, the best match, recipe search, or the meal-log picker's full list.
  func testNoQuarantinedRecipeIsEverOffered() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let quarantinedIDs = try await quarantinedLegacyIDs(db)
    XCTAssertEqual(quarantinedIDs.count, 25, "fl-seed-0001...0025 ship as legacy rows")
    let everything = try await db.read { db in
      Set(try Int64.fetchAll(db, sql: "SELECT id FROM ingredients"))
    }

    let exact = try repo.findMakeable(with: everything, profile: .default, limit: 2_000)
    let near = try repo.findNearMatch(
      with: everything, profile: .default, maxMissingRequired: 2, limit: 2_000)
    XCTAssertFalse(exact.isEmpty, "the full kitchen matches something, so the check is not vacuous")
    for scored in exact + near {
      XCTAssertFalse(
        quarantinedIDs.contains(scored.recipe.id ?? -1), "offered \(scored.recipe.title)")
    }
    for pantry in [everything, Set([1, 2, 3])] {
      let best = try repo.quickSuggestion(with: pantry, profile: .default)
      XCTAssertFalse(quarantinedIDs.contains(best?.recipe.id ?? -1), "hero \(best?.recipe.title ?? "")")
    }

    let picker = try repo.fetchAllRecipes(limit: 2_000)
    XCTAssertFalse(picker.isEmpty)
    XCTAssertFalse(picker.contains { quarantinedIDs.contains($0.recipe.id ?? -1) })
    for entry in try RecipeQuarantine.load(from: .main) where entry.legacyRecipeID != nil {
      XCTAssertFalse(
        try repo.searchRecipes(query: entry.recipe.title, limit: 100)
          .contains { quarantinedIDs.contains($0.recipe.id ?? -1) },
        "search offers \(entry.recipe.title)")
    }
  }

  // MARK: - Amounts, legacy pool

  /// Legacy "Easiest ever seafood rice" (id 72) needs 25 g, 55 g, 300 g and 200 g of four
  /// ingredients for its two servings.
  private let seafoodRiceID: Int64 = 72

  func testLegacyRecipeWithTooLittleOfOneLineIsNotComplete() async throws {
    let db = try await makeShippedDatabase()
    let lines = try await legacyRequiredLines(db, recipeID: seafoodRiceID)
    let short = try XCTUnwrap(lines.max { $0.grams < $1.grams })
    try await stock(db, lines.map { ($0.id, $0.id == short.id ? short.grams / 2 : $0.grams, false) })

    let scored = try offered(makeRepository(db), lines.map(\.id), legacy: seafoodRiceID)
    XCTAssertEqual(scored.matchTier, .nearMatch)
    XCTAssertFalse(scored.isCompleteMatch)
    XCTAssertEqual(
      scored.insufficientRequiredLines,
      [InsufficientRequiredLine(ingredientIDs: [short.id], supply: .short(grams: short.grams / 2))])
    XCTAssertFalse(scored.rankingReasons.contains("Complete match"))
    XCTAssertEqual(scored.rankingReasons.first, "Short on 1 ingredient")
    XCTAssertEqual(scored.requiredHadInFull, lines.count - 1)
    XCTAssertEqual(
      RecipeIngredientMark.mark(
        ingredientID: short.id, isRequired: true, isSubstituted: false,
        missingRequiredIDs: Set(scored.missingIngredientIds),
        insufficientSupply: scored.insufficientSupplyByIngredientID),
      .short(grams: short.grams / 2))
  }

  func testLegacyRecipeWithAnEstimatedLineSaysCheckAmount() async throws {
    let db = try await makeShippedDatabase()
    let lines = try await legacyRequiredLines(db, recipeID: seafoodRiceID)
    let estimated = lines[0]
    try await stock(db, lines.map { ($0.id, $0.grams * 2, $0.id == estimated.id) })

    let scored = try offered(makeRepository(db), lines.map(\.id), legacy: seafoodRiceID)
    XCTAssertEqual(scored.matchTier, .nearMatch)
    XCTAssertEqual(
      scored.insufficientRequiredLines,
      [InsufficientRequiredLine(ingredientIDs: [estimated.id], supply: .checkAmount)])
    XCTAssertEqual(scored.rankingReasons.first, "Check amounts")
  }

  func testLegacyRecipeWithExactlyEnoughIsCompleteAndOneGramLessIsNot() async throws {
    let db = try await makeShippedDatabase()
    let lines = try await legacyRequiredLines(db, recipeID: seafoodRiceID)
    try await stock(db, lines.map { ($0.id, $0.grams, false) })
    let repo = makeRepository(db)

    let scored = try offered(repo, lines.map(\.id), legacy: seafoodRiceID)
    XCTAssertEqual(scored.matchTier, .exact)
    XCTAssertTrue(scored.isCompleteMatch)
    XCTAssertEqual(scored.rankingReasons.first, "Complete match")

    try await db.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = remaining_grams - 1 WHERE ingredient_id = ?",
        arguments: [lines[0].id])
    }
    XCTAssertEqual(try offered(repo, lines.map(\.id), legacy: seafoodRiceID).matchTier, .nearMatch)
  }

  // MARK: - Amounts, catalog pool

  func testCatalogRecipeWithTooLittleOfOneLineIsNotComplete() async throws {
    let db = try await makeShippedDatabase()
    let recipe = try await catalogCase(db)
    let short = recipe.lines[0]
    try await stock(
      db, recipe.lines.map { ($0.id, $0.id == short.id ? short.grams / 2 : $0.grams, false) })

    let scored = try offered(makeRepository(db), recipe.lines.map(\.id), catalog: recipe.catalogID)
    XCTAssertEqual(scored.matchTier, .nearMatch)
    XCTAssertEqual(
      scored.insufficientRequiredLines,
      [InsufficientRequiredLine(ingredientIDs: [short.id], supply: .short(grams: short.grams / 2))])
    XCTAssertFalse(scored.rankingReasons.contains("Complete match"))
  }

  func testCatalogRecipeWithAnEstimatedLineSaysCheckAmount() async throws {
    let db = try await makeShippedDatabase()
    let recipe = try await catalogCase(db)
    let estimated = recipe.lines[0]
    try await stock(db, recipe.lines.map { ($0.id, $0.grams * 2, $0.id == estimated.id) })

    let scored = try offered(makeRepository(db), recipe.lines.map(\.id), catalog: recipe.catalogID)
    XCTAssertEqual(scored.matchTier, .nearMatch)
    XCTAssertEqual(
      scored.insufficientRequiredLines,
      [InsufficientRequiredLine(ingredientIDs: [estimated.id], supply: .checkAmount)])
  }

  func testCatalogRecipeWithExactlyEnoughIsCompleteAndOneGramLessIsNot() async throws {
    let db = try await makeShippedDatabase()
    let recipe = try await catalogCase(db)
    try await stock(db, recipe.lines.map { ($0.id, $0.grams, false) })
    let repo = makeRepository(db)

    let scored = try offered(repo, recipe.lines.map(\.id), catalog: recipe.catalogID)
    XCTAssertEqual(scored.matchTier, .exact)
    XCTAssertTrue(scored.isCompleteMatch)

    try await db.write { db in
      try db.execute(
        sql: "UPDATE inventory_lots SET remaining_grams = remaining_grams - 1 WHERE ingredient_id = ?",
        arguments: [recipe.lines[0].id])
    }
    XCTAssertEqual(
      try offered(repo, recipe.lines.map(\.id), catalog: recipe.catalogID).matchTier, .nearMatch)
  }

  // MARK: - Supply rule

  func testSupplyJudgement() {
    let judge = IngredientSupply.judge
    XCTAssertEqual(judge(100, false, OnHandStock(confirmedGrams: 500)), .missing)
    XCTAssertEqual(judge(100, true, OnHandStock(confirmedGrams: 100)), .have)
    XCTAssertEqual(judge(100, true, OnHandStock(confirmedGrams: 50)), .short(grams: 50))
    XCTAssertEqual(
      judge(100, true, OnHandStock(confirmedGrams: 50, estimatedGrams: 500)), .checkAmount)
    XCTAssertEqual(
      judge(100, true, OnHandStock(confirmedGrams: 100, estimatedGrams: 5)), .have,
      "confirmed stock that covers the line needs no estimate")
    XCTAssertEqual(judge(nil, true, OnHandStock(confirmedGrams: 1)), .have, "no amount to compare")
    XCTAssertEqual(judge(100, true, nil), .have, "no lot: presence decides")
    XCTAssertEqual(InsufficientRequiredLine.formatGrams(0.4), "1 g")
  }

  // MARK: - Results below a catalog hero

  /// Catalog entries all carry a nil `recipe.id`, so a catalog hero was never left out of the
  /// list below it.
  func testCatalogHeroIsLeftOutOfTheListBelowIt() {
    let hero = catalogScored("rcp-000500")
    let other = catalogScored("rcp-000501")
    let sections = RecommendationSections(exact: [], nearMatch: [hero, other])
    XCTAssertEqual(sections.belowBestMatch.nearMatch.map(\.id), [other.id])
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

  private func quarantinedLegacyIDs(_ db: DatabaseQueue) async throws -> Set<Int64> {
    let keys = RecipeQuarantine.legacyTitleKeys(try RecipeQuarantine.load(from: .main))
    return try await db.read { db in
      Set(
        try Row.fetchAll(db, sql: "SELECT id, title FROM recipes WHERE source = 'bundled'")
          .filter { keys.contains(($0["title"] as String).trimmingCharacters(in: .whitespaces).lowercased()) }
          .map { $0["id"] as Int64 })
    }
  }

  private func legacyRequiredLines(_ db: DatabaseQueue, recipeID: Int64) async throws
    -> [(id: Int64, grams: Double)]
  {
    let lines = try await db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_id, quantity_grams FROM recipe_ingredients
          WHERE recipe_id = ? AND is_required = 1 ORDER BY ingredient_id
          """,
        arguments: [recipeID]
      ).map { (id: $0["ingredient_id"] as Int64, grams: $0["quantity_grams"] as Double) }
    }
    XCTAssertGreaterThanOrEqual(lines.count, 2)
    return lines
  }

  /// A shipped catalog recipe whose required lines each have a gram amount and bridge to an
  /// app ingredient no other line of the recipe bridges to, so each line's stock is one lot.
  private func catalogCase(_ db: DatabaseQueue) async throws
    -> (catalogID: String, lines: [(id: Int64, grams: Double)])
  {
    let found = try await db.read { db -> (String, [(id: Int64, grams: Double)])? in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT l.catalog_id, l.ingredient_key, l.quantity_grams, l.is_required, l.assumed_staple
          FROM recipes_catalog_lines l
          JOIN recipes_catalog r ON r.catalog_id = l.catalog_id
          WHERE r.rights_status = 'original'
          ORDER BY l.catalog_id, l.position
          """)
      var bridge: [String: Set<Int64>] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge")
      {
        bridge[row["ingredient_key"], default: []].insert(row["ingredient_id"])
      }
      var byRecipe: [String: [Row]] = [:]
      var order: [String] = []
      for row in rows {
        let id: String = row["catalog_id"]
        if byRecipe[id] == nil { order.append(id) }
        byRecipe[id, default: []].append(row)
      }
      for catalogID in order {
        let recipeRows = byRecipe[catalogID]!
        let allBridged = recipeRows.map { bridge[$0["ingredient_key"] as String] ?? [] }
        var lines: [(id: Int64, grams: Double)] = []
        var usable = true
        for (index, row) in recipeRows.enumerated() {
          let required: Bool = row["is_required"]
          let staple: Bool = row["assumed_staple"]
          guard required, !staple else { continue }
          let grams: Double? = row["quantity_grams"]
          let others = allBridged.enumerated().filter { $0.offset != index }
            .reduce(into: Set<Int64>()) { $0.formUnion($1.element) }
          guard let grams, grams > 0, let id = allBridged[index].subtracting(others).min(),
            allBridged[index].count == 1
          else {
            usable = false
            break
          }
          lines.append((id, grams))
        }
        if usable, lines.count >= 2 { return (catalogID, lines) }
      }
      return nil
    }
    let (catalogID, lines) = try XCTUnwrap(found, "no shipped catalog recipe fits the case")
    return (catalogID, lines)
  }

  private func stock(_ db: DatabaseQueue, _ lots: [(Int64, Double, Bool)]) async throws {
    try await db.write { db in
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

  /// The entry for one recipe from the tier searches Results runs, exact first.
  private func offered(
    _ repo: RecipeRepository, _ pantry: [Int64], legacy: Int64? = nil, catalog: String? = nil
  ) throws -> ScoredRecipe {
    let ids = Set(pantry)
    let all =
      try repo.findMakeable(with: ids, profile: .default, limit: 2_000)
      + repo.findNearMatch(with: ids, profile: .default, maxMissingRequired: 2, limit: 2_000)
    let match = all.first { scored in
      if let legacy { return scored.recipe.id == legacy && scored.catalog == nil }
      return scored.catalog?.ref.id == catalog
    }
    return try XCTUnwrap(match, "recipe not offered for its own ingredients")
  }

  private func catalogScored(_ catalogID: String) -> ScoredRecipe {
    ScoredRecipe(
      recipe: Recipe(
        id: nil, title: catalogID, timeMinutes: 10, servings: 2, instructions: "",
        tags: 0, source: .bundled, createdAt: nil),
      matchedRequired: 1,
      totalRequired: 2,
      matchedOptional: 0,
      missingRequiredCount: 1,
      missingIngredientIds: [99],
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
        fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
      healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
      personalScore: 0,
      rankingScore: 0,
      rankingReasons: [],
      matchTier: .nearMatch,
      catalog: CatalogRecipeMatch(
        ref: .catalog(id: catalogID, revision: 1), successorToLegacyRecipeID: nil)
    )
  }
}
