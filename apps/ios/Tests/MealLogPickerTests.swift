import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// Log a Meal's recipe picker read only the legacy table, so it listed 38 recipes and found
/// none of the 762 catalog originals by name (2026-10-16 walk at alpha a32bfe3: "fried rice"
/// and "peanut" found nothing). A catalog pick also had no way to log: `resolveForLogging`
/// returns nil for it and the log carried no catalog id or revision.
final class MealLogPickerTests: XCTestCase {
  // MARK: - Logging a catalog pick

  func testCatalogPickLogsWithItsCatalogIDRevisionAndNutrition() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let entry = try XCTUnwrap(
      try repo.mealLogRecipes(matching: "fried rice", limit: 200)
        .first { $0.recipe.title == "Golden Fried Rice with Sweet Peas" },
      "the picker finds the catalog recipe by title")
    let ref = try XCTUnwrap(entry.catalogRef, "the entry is the catalog recipe, not a legacy row")
    XCTAssertEqual(ref.id, "rcp-000806")

    let pick = try repo.catalogMealLogPick(ref)
    XCTAssertEqual(pick.catalogRef, ref)
    let snapshot = try XCTUnwrap(try repo.catalogNutrition(catalogId: ref.id, revision: ref.revision))
    XCTAssertEqual(pick.macros.caloriesPerServing, snapshot.kcal, accuracy: 0.001)
    XCTAssertEqual(pick.macros.proteinPerServing, snapshot.proteinG, accuracy: 0.001)

    let outcome = try MealLogService(
      db: db, recipeRepository: repo, personalizationService: PersonalizationService(db: db),
      inventoryRepository: InventoryRepository(db: db), imageStorageService: ImageStorageService()
    ).logMeal(
      recipe: pick.recipe, imagePath: nil, servingsConsumed: 1,
      catalog: CatalogMealLog(id: ref.id, revision: ref.revision, stock: .leaveKitchen))

    let link = try catalogLink(db, historyID: outcome.historyId)
    XCTAssertEqual(link?.catalogID, ref.id)
    XCTAssertEqual(link?.revision, ref.revision)
    XCTAssertEqual(
      try repo.catalogNutrition(forHistoryID: outcome.historyId)?.kcal, snapshot.kcal,
      "the logged meal reports the catalog's per-serving nutrition")

    // Logging lands on an ingredientless `recipes` row with the catalog title. The picker still
    // offers the dish once, as the catalog entry, so the next log links the catalog again.
    let again = try repo.mealLogRecipes(matching: "Golden Fried Rice with Sweet Peas", limit: 200)
    XCTAssertEqual(again.map(\.catalogRef), [ref])
  }

  // MARK: - Search

  func testSearchFindsCatalogRecipesByTitleAndMarksTheFlaggedOnes() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let ingredients = try allIngredients(db)
    let peanutGroup = try XCTUnwrap(AllergenSupport.groups.first { $0.id == "peanut" })
    let peanutID = try XCTUnwrap(AllergenSupport.matchingIDs(for: peanutGroup, in: ingredients).max())
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[\(peanutID)]"
    try UserDataRepository(db: db).saveHealthProfile(profile)

    let peanut = try repo.mealLogRecipes(matching: "peanut", limit: 200)
    let slaw = try XCTUnwrap(
      peanut.first { $0.recipe.title == "Crunchy Peanut and Lime Slaw" },
      "a peanut household still finds the recipe, so it can log what it ate")
    XCTAssertNotNil(slaw.catalogRef)
    XCTAssertEqual(slaw.verdict, .blocked(.allergen(.peanut)))
    XCTAssertEqual(slaw.warning, "Contains peanut")
    for entry in peanut {
      XCTAssertEqual(entry.warning == nil, entry.verdict.isAllowed, entry.recipe.title)
    }

    let friedRice = try XCTUnwrap(
      try repo.mealLogRecipes(matching: "FRIED RICE", limit: 200)
        .first { $0.recipe.title == "Golden Fried Rice with Sweet Peas" })
    XCTAssertEqual(friedRice.verdict, .allowed)
    XCTAssertNil(friedRice.warning)
  }

  /// The empty search lists every recipe the app offers: all catalog originals and every legacy
  /// recipe the hide lists leave, and nothing they hide.
  func testEmptySearchListsBothPoolsAndNothingTheHideListsHide() async throws {
    let db = try await makeShippedDatabase()
    let repo = makeRepository(db)
    let all = try repo.mealLogRecipes(matching: "", limit: 5_000)
    let originals = try originalCatalogCount(db)
    XCTAssertGreaterThan(originals, 700)
    XCTAssertEqual(all.filter { $0.catalogRef != nil }.count, originals)
    let legacy = all.filter { $0.catalogRef == nil }
    XCTAssertEqual(legacy.count, try repo.fetchAllRecipes(limit: 5_000).count)
    XCTAssertFalse(legacy.isEmpty)

    // The hide lists name legacy rows. A catalog original may share a hidden row's title
    // ("Garlic Butter Pasta", rcp-000994, is a new original with its own rights evidence);
    // the catalog side is covered by counting only `original` rows above.
    let hidden = RecipeQuarantine.legacyTitleKeys()
    for entry in legacy {
      XCTAssertFalse(
        hidden.contains(entry.recipe.title.trimmingCharacters(in: .whitespaces).lowercased()),
        "offers hidden \(entry.recipe.title)")
    }
    XCTAssertEqual(Set(all.map(\.listKey)).count, all.count, "every entry appears once")
  }

  /// The picker names why a catalog recipe is refused but never decides it: for every
  /// restricted household, its verdict allows exactly what the shared admission rule admits.
  func testCatalogVerdictAllowsExactlyWhatAdmissionAdmits() async throws {
    let db = try await makeShippedDatabase()
    let ingredients = try allIngredients(db)
    var profiles: [HealthProfile] = []
    for group in AllergenSupport.groups {
      guard let id = AllergenSupport.matchingIDs(for: group, in: ingredients).max() else { continue }
      var profile = HealthProfile.default
      profile.allergenIngredientIds = "[\(id)]"
      profiles.append(profile)
    }
    for diet in ["vegetarian", "vegan", "pescatarian", "keto"] {
      var profile = HealthProfile.default
      profile.dietaryRestrictions = "[\"\(diet)\"]"
      profiles.append(profile)
    }

    var refusals = 0
    for profile in profiles {
      for recipe in try judgeCatalog(db, profile: profile) {
        XCTAssertEqual(
          recipe.verdictAllows, recipe.admitted,
          "\(recipe.catalogID) for \(profile.allergenIngredientIds) \(profile.dietaryRestrictions)")
        if !recipe.admitted { refusals += 1 }
      }
    }
    XCTAssertGreaterThan(refusals, 0, "no household refused anything, so the check is vacuous")
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

  private func allIngredients(_ db: DatabaseQueue) throws -> [Ingredient] {
    try db.read { db in try Ingredient.fetchAll(db) }
  }

  private func originalCatalogCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes_catalog WHERE rights_status = 'original'")
        ?? 0
    }
  }

  private func catalogLink(_ db: DatabaseQueue, historyID: Int64) throws
    -> (catalogID: String, revision: Int)?
  {
    try db.read { db in
      try Row.fetchOne(
        db, sql: "SELECT catalog_id, revision FROM recipes_cooking_catalog_refs WHERE history_id = ?",
        arguments: [historyID]
      ).map { (catalogID: $0["catalog_id"], revision: $0["revision"]) }
    }
  }

  /// Every catalog original judged two ways for `profile`: the shared admission rule, and the
  /// verdict the picker shows.
  private func judgeCatalog(_ db: DatabaseQueue, profile: HealthProfile) throws
    -> [(catalogID: String, admitted: Bool, verdictAllows: Bool)]
  {
    try db.read { db in
      var keysByRecipe: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT catalog_id, ingredient_key FROM recipes_catalog_lines ORDER BY position")
      {
        keysByRecipe[row["catalog_id"], default: []].append(row["ingredient_key"])
      }
      let boundary = try HouseholdSafetyBoundary.load(profile: profile, in: db)
      return try Row.fetchAll(
        db, sql: "SELECT catalog_id, claims FROM recipes_catalog WHERE rights_status = 'original'"
      ).map { header in
        let catalogID: String = header["catalog_id"]
        let claims: String? = header["claims"]
        let keys = keysByRecipe[catalogID] ?? []
        return (
          catalogID: catalogID,
          admitted: boundary.admitsCatalogRecipe(lineKeys: keys, claimsJSON: claims),
          verdictAllows: RecipeRepository.catalogMealLogVerdict(
            boundary: boundary, lineKeys: keys, claimsJSON: claims
          ).isAllowed
        )
      }
    }
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
}

extension HouseholdScreenedRecipe {
  fileprivate var listKey: String {
    catalogRef.map { "catalog-\($0.id)" } ?? "legacy-\(recipe.id ?? -1)"
  }
}
