import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// One household screen behind every path that hands the household a recipe or a swap:
/// legacy and catalog recommendations, the weekly and guest plans, saved-plan reloads,
/// recipe search, the catalog browse list, and every substitution path. Each test below
/// reproduces one leak found in review on alpha 9e4a3af5, so it failed before the shared
/// boundary existed.
final class HouseholdSafetyBoundaryTests: XCTestCase {
  // MARK: - Finding 1: legacy recipes skipped the composition screen

  /// The legacy pool ran only the diet tag mask and exact excluded ids. Pescatarian has no
  /// tag, so the bundled Beef Taco Bowl (ground beef, ingredient 38) reached
  /// recommendations, the weekly plan and the guest plan.
  func testPescatarianHouseholdIsNeverOfferedTheBundledBeefTacoBowl() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let tacoBowlID: Int64 = 17
    let tacoBowlPantry: Set<Int64> = [38, 2, 27, 7]
    XCTAssertEqual(try repo.fetchRecipe(id: tacoBowlID)?.title, "Beef Taco Bowl")
    XCTAssertTrue(
      try repo.findMakeable(with: tacoBowlPantry, profile: .default, limit: 200)
        .contains { $0.recipe.id == tacoBowlID },
      "an unrestricted household is offered the taco bowl, so the checks below are not vacuous")

    let pescatarian = try saveProfile(db, diet: "pescatarian")

    XCTAssertFalse(
      try repo.findMakeable(with: tacoBowlPantry, profile: pescatarian, limit: 200)
        .contains { $0.recipe.id == tacoBowlID })
    XCTAssertFalse(
      try repo.findNearMatch(with: tacoBowlPantry.subtracting([7]), profile: pescatarian, limit: 200)
        .contains { $0.recipe.id == tacoBowlID })
    XCTAssertFalse(
      try PlanDataAdapter(dbQueue: db).loadSnapshot().candidates
        .contains { $0.databaseID == tacoBowlID },
      "weekly plan")
    XCTAssertFalse(
      try GuestMealSnapshot.load(from: db, now: Date()).recipes
        .contains { $0.databaseID == tacoBowlID },
      "guest plan")
  }

  /// Every restricted household against every legacy-recipe surface, re-screened here from
  /// the bundle's classes: a legacy line takes the classes of every vocabulary key its
  /// ingredient bridges to, and an ingredient with no bridge row is unknown composition.
  /// Allergen households store one id per group (the largest matching row), so recipe lines
  /// on any other member of the group can only be caught by class.
  func testNoSurfaceOffersALegacyRecipeTheHouseholdScreenRefuses() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let lineSafety = try lineSafetyByIngredientID(db)
    let legacyLines = try legacyLinesByRecipeID(db)
    let pantry = Set(legacyLines.values.joined())

    for (household, profile) in try restrictedHouseholds(db) {
      try UserDataRepository(db: db).saveHealthProfile(profile)
      let flagged = try identityClass(
        of: Set(profile.parsedAllergenIds).union(profile.dietaryExcludedIngredientIds), db)

      func check(_ surface: String, recipeID: Int64, lines: [Int64]) {
        if let hit = lines.first(where: flagged.contains) {
          XCTFail("\(surface) offered legacy recipe \(recipeID) with flagged ingredient \(hit) to \(household)")
          return
        }
        let verdict = HouseholdSafetyGate.screen(
          household: household, lines: lines.map { lineSafety[$0] ?? .unknown })
        XCTAssertEqual(
          verdict, .allowed, "\(surface) offered legacy recipe \(recipeID) to \(household)")
      }

      let recommended =
        try repo.findMakeable(with: pantry, profile: profile, limit: 1_000)
        + repo.findNearMatch(with: pantry, profile: profile, limit: 1_000)
      for result in recommended where result.catalog == nil {
        guard let id = result.recipe.id else { continue }
        check("recommendations", recipeID: id, lines: legacyLines[id] ?? [])
      }
      for candidate in try PlanDataAdapter(dbQueue: db).loadSnapshot().candidates
      where candidate.databaseID > 0 {
        check("weekly plan", recipeID: candidate.databaseID, lines: candidate.lines.map(\.ingredientID))
      }
      for candidate in try GuestMealSnapshot.load(from: db, now: Date()).recipes
      where candidate.databaseID > 0 {
        check("guest plan", recipeID: candidate.databaseID, lines: candidate.lines.map(\.ingredientID))
      }
    }
  }

  // MARK: - Finding 2: one substitute key, several app ids

  /// A substitute key can bridge to several app ingredients. Offers kept only the smallest
  /// id and screened only that one, so a household that flagged the key's other id was
  /// still offered the swap. "Maize starch" matches no allergen keyword group, so only the
  /// id check can catch it.
  func testFlagOnAnyBridgedIDOfASubstituteKeyBlocksTheSwap() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (20, 'all purpose flour', 364, 10, 76, 1),
            (21, 'cornstarch', 381, 0.3, 91, 0.1),
            (22, 'maize starch', 381, 0.3, 91, 0.1);
          INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category, classes) VALUES
            ('all_purpose_flour', NULL, NULL, 'All-purpose flour', 'grain', '["gluten","plant"]'),
            ('cornstarch', NULL, NULL, 'Cornstarch', 'grain', '["plant"]');
          INSERT INTO recipes_catalog_ingredient_bridge
            (ingredient_key, ingredient_id, resolved_by) VALUES
            ('all_purpose_flour', 20, 'fdc_id'),
            ('cornstarch', 21, 'fdc_id'),
            ('cornstarch', 22, 'fdc_id');
          """)
    }
    let service = SubstitutionService(db: db)
    XCTAssertTrue(
      service.substitutions(for: 20).contains { $0.substituteKey == "cornstarch" && $0.substituteId == 21 },
      "unflagged, the reviewed flour -> cornstarch swap is offered under the key's smallest id")

    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[22]"
    try UserDataRepository(db: db).saveHealthProfile(profile)

    XCTAssertFalse(service.substitutions(for: 20).contains { $0.substituteKey == "cornstarch" })
    XCTAssertFalse(
      service.screenedSubstitutions(for: 20).contains { $0.swap.substituteKey == "cornstarch" })
    XCTAssertFalse(service.hasSubstitutions(for: 20), "cornstarch was flour's only bridged swap")
    let recheck = service.substitutionRecheck(for: 20, substituteId: 21, eaters: [])
    XCTAssertEqual(recheck.verdict, .unsupported)
    XCTAssertFalse(recheck.allowsSwap)
    XCTAssertEqual(service.substituteIsAllergen(for: 21), true)
  }

  // MARK: - Finding 3: search took no household

  /// The meal-log picker searches every recipe so a household can log what it actually ate,
  /// so a flagged recipe stays in the results, marked with the reason.
  func testSearchMarksFlaggedRecipesInsteadOfOfferingThemPlain() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let legacyLines = try legacyLinesByRecipeID(db)
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[41]"  // peanut_butter
    try UserDataRepository(db: db).saveHealthProfile(profile)

    let smoothie = try XCTUnwrap(
      try repo.searchRecipes(query: "peanut", limit: 100)
        .first { $0.recipe.title == "Peanut Butter Banana Smoothie" },
      "search still finds the meal")
    XCTAssertEqual(smoothie.verdict, .blocked(.allergen(.peanut)))
    XCTAssertNotNil(smoothie.warning)

    for entry in try repo.fetchAllRecipes(limit: 1_000)
    where legacyLines[entry.recipe.id ?? -1, default: []].contains(41) {
      XCTAssertNotNil(entry.warning, "\(entry.recipe.title) contains peanut butter but is unmarked")
    }

    let friedRice = try XCTUnwrap(
      try repo.searchRecipes(query: "Classic Egg Fried Rice").first)
    XCTAssertEqual(friedRice.verdict, .allowed)
    XCTAssertNil(friedRice.warning)

    _ = try saveProfile(db, diet: "vegetarian")
    let tacoBowl = try XCTUnwrap(
      try repo.searchRecipes(query: "Beef Taco Bowl").first)
    XCTAssertEqual(tacoBowl.verdict, .blocked(.diet(.vegetarian)))
    XCTAssertNotNil(tacoBowl.warning)
  }

  // MARK: - Finding 4: saved plans were never re-screened

  /// A plan saved before the household changed its profile kept every dinner on reload and
  /// kept reserving stock for them. Dinners the household may no longer eat leave the
  /// reloaded plan, its shopping list, and the stock reservations.
  func testSavedPlanDropsDinnersTheHouseholdCanNoLongerEat() throws {
    let db = try LeChefPlanWeeklyTests.makeDatabase()
    try LeChefPlanWeeklyTests.seedCatalog(db)
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions) VALUES (2, 'Chicken Plate', 25, 'x')")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_grams, display_quantity)
          VALUES (2, 4, 300, '300 g')
          """)
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let adapter = PlanDataAdapter(dbQueue: db, now: now)
    func line(_ id: Int64, _ name: String, _ grams: Double, short: Double? = nil) -> PlanLine {
      PlanLine(
        ingredientID: id, name: name, isRequired: true, required: PlanQuantity(value: grams),
        lineState: short == nil ? .sufficient : .short, short: short.map { PlanQuantity(value: $0) },
        swap: nil)
    }
    func dinner(
      _ position: Int, ref: String, databaseID: Int64, title: String, lines: [PlanLine]
    ) -> PlannedDinner {
      PlannedDinner(
        position: position, dinnerID: "plan_saved-d\(position)",
        recipe: RecipeRef(source: .catalog, id: ref, revision: 1), recipeDatabaseID: databaseID,
        title: title, servings: 2, timeMinutes: nil, lines: lines)
    }
    try adapter.save(
      LeChefPlan(
        planID: "plan_saved", createdAt: now,
        dinners: [
          dinner(1, ref: "2", databaseID: 2, title: "Chicken Plate", lines: [line(4, "chicken", 300)]),
          dinner(
            2, ref: "rcp-000204", databaseID: -204, title: "Chicken Dinner",
            lines: [line(4, "chicken", 150, short: 50)]),
          dinner(3, ref: "1", databaseID: 1, title: "Fried Rice", lines: [line(1, "rice", 200)]),
        ],
        shoppingList: [],
        fitSummary: PlanFitSummary(sufficientLines: 2, totalLines: 3, swapCount: 0, attention: nil)))
    XCTAssertEqual(
      try adapter.loadSnapshot().pool.availableGrams(4), 0, accuracy: 0.001,
      "both chicken dinners reserve the 400 g of chicken while the household may eat them")

    try db.write { db in
      try db.execute(
        sql: "UPDATE health_profile SET dietary_restrictions = '[\"pescatarian\"]' WHERE id = 1")
    }

    let reloaded = try XCTUnwrap(try adapter.load(planID: "plan_saved"))
    XCTAssertEqual(reloaded.dinners.map(\.dinnerID), ["plan_saved-d3"])
    XCTAssertFalse(
      reloaded.shoppingList.contains { $0.ingredientID == 4 },
      "no chicken is bought for a dinner the household no longer eats")
    let pool = try adapter.loadSnapshot().pool
    XCTAssertEqual(pool.availableGrams(4), 400, accuracy: 0.001, "chicken is no longer reserved")
    XCTAssertEqual(pool.availableGrams(1), 200, accuracy: 0.001, "the rice dinner still reserves")
  }

  // MARK: - Finding 5: direct catalog reads had no safety boundary

  /// The catalog browse list takes the household and leaves out what its screen refuses.
  func testCatalogBrowseListOmitsRecipesTheHouseholdScreenRefuses() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let peanutKeys = try await db.read { db in
      Set(
        try String.fetchAll(
          db, sql: "SELECT key FROM recipes_catalog_ingredients WHERE classes LIKE '%\"peanut\"%'"))
    }
    func hasPeanutLine(_ recipe: RecipeCatalogRecipe) -> Bool {
      recipe.lines.contains { peanutKeys.contains($0.key) }
    }
    let everything = try repo.catalogRecipes(for: .default, limit: 5_000)
    XCTAssertTrue(everything.contains(where: hasPeanutLine), "the shipped catalog has peanut recipes")

    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[41]"  // peanut_butter
    let screened = try repo.catalogRecipes(for: profile, limit: 5_000)
    XCTAssertFalse(screened.contains(where: hasPeanutLine))
    XCTAssertFalse(screened.isEmpty)
  }

  // MARK: - Open contract question (pinned, not changed)

  /// Open decision for Sam: a flagged ingredient that matches no allergen keyword group is
  /// dropped by `HouseholdSafetyProfileResolver.householdProfile`. The household then has
  /// no allergen group, so it is not "restricted": recipes with unknown composition still
  /// reach it, and the flag blocks only that ingredient and ids bridged to the same key.
  /// Whether such a flag should make the household restricted is a product call; this test
  /// pins today's behavior so a change to it is deliberate.
  func testFlaggedIngredientWithNoAllergenGroupLeavesTheHouseholdUnrestricted() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (22, 'maize starch', 381, 0.3, 91, 0.1)")
    }
    let household = try db.read { db in
      try HouseholdSafetyProfileResolver.householdProfile(allergenIds: [22], dietID: nil, in: db)
    }
    XCTAssertEqual(household.allergenGroups, [])
    XCTAssertFalse(household.hasAnyRestriction)
    XCTAssertEqual(
      HouseholdSafetyGate.screen(household: household, line: .unknown), .allowed,
      "unknown composition is not refused for this household")
  }

  // MARK: - Fixtures

  /// A fresh database hydrated the way the app hydrates on first launch: legacy data.json,
  /// the USDA ingredient catalog, then the shipped v2 bundle and its identity bridge.
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

  @discardableResult
  private func saveProfile(_ db: DatabaseQueue, diet: String) throws -> HealthProfile {
    var profile = HealthProfile.default
    profile.dietaryRestrictions = "[\"\(diet)\"]"
    try UserDataRepository(db: db).saveHealthProfile(profile)
    return profile
  }

  /// One household per allergen group, plus the diets whose classes the gate screens. Keto
  /// is left out: no class expresses it, so legacy rows prove it by their low-carb tag.
  private func restrictedHouseholds(
    _ db: DatabaseQueue
  ) throws -> [(household: HouseholdSafetyProfile, profile: HealthProfile)] {
    let ingredients = try db.read { db in try Ingredient.fetchAll(db) }
    var households: [(household: HouseholdSafetyProfile, profile: HealthProfile)] = []
    for definition in AllergenSupport.groups {
      guard let group = HouseholdAllergenGroup(rawValue: definition.id),
        let storedID = AllergenSupport.matchingIDs(for: definition, in: ingredients).max()
      else { continue }
      var profile = HealthProfile.default
      profile.allergenIngredientIds = "[\(storedID)]"
      households.append((HouseholdSafetyProfile(allergenGroups: [group]), profile))
    }
    for diet in [HouseholdDiet.vegetarian, .vegan, .pescatarian] {
      var profile = HealthProfile.default
      profile.dietaryRestrictions = "[\"\(diet.rawValue)\"]"
      households.append((HouseholdSafetyProfile(diet: diet), profile))
    }
    return households
  }

  /// Every line of every legacy recipe, required and optional.
  private func legacyLinesByRecipeID(_ db: DatabaseQueue) throws -> [Int64: [Int64]] {
    try db.read { db in
      var lines: [Int64: [Int64]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT recipe_id, ingredient_id FROM recipe_ingredients ORDER BY recipe_id")
      {
        lines[row["recipe_id"], default: []].append(row["ingredient_id"])
      }
      return lines
    }
  }

  /// An app ingredient's composition: the classes of every vocabulary key it bridges to.
  /// A key with no classes makes the ingredient unknown; ids with no bridge row are absent.
  private func lineSafetyByIngredientID(_ db: DatabaseQueue) throws -> [Int64: RecipeLineSafety] {
    try db.read { db in
      var classes: [Int64: Set<String>] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT b.ingredient_id, v.classes FROM recipes_catalog_ingredient_bridge b
          LEFT JOIN recipes_catalog_ingredients v ON v.key = b.ingredient_key
          """)
      {
        let raw: String? = row["classes"]
        let decoded = raw.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        let keyClasses = decoded.flatMap { $0.isEmpty ? nil : $0 } ?? ["unknown"]
        classes[row["ingredient_id"], default: []].formUnion(keyClasses)
      }
      return classes.mapValues { RecipeLineSafety(classes: $0) }
    }
  }

  /// The flagged ids plus every app id bridged to the same vocabulary key as one of them.
  private func identityClass(of ids: Set<Int64>, _ db: DatabaseQueue) throws -> Set<Int64> {
    guard !ids.isEmpty else { return [] }
    let list = ids.map(String.init).joined(separator: ",")
    return try db.read { db in
      ids.union(
        try Int64.fetchAll(
          db,
          sql: """
            SELECT other.ingredient_id FROM recipes_catalog_ingredient_bridge flagged
            JOIN recipes_catalog_ingredient_bridge other ON other.ingredient_key = flagged.ingredient_key
            WHERE flagged.ingredient_id IN (\(list))
            """))
    }
  }
}
