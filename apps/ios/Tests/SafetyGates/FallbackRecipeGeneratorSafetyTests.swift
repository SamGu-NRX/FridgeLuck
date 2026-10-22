import GRDB
import XCTest

@testable import FridgeLuck

/// The local fallback generator screened its suggestion against `HealthProfile.default`,
/// which has no allergens, so a household's stored allergies never reached it.
final class FallbackRecipeGeneratorSafetyTests: XCTestCase {
  /// The ingredients of the bundled chilli con carne (recipe 59), which an unrestricted
  /// household can make in full. HouseholdSafetyBoundaryTests relies on the same pantry.
  private let pantry: Set<Int64> = [38, 21, 6, 47, 3, 7]

  func testFallbackScreensAgainstTheStoredAllergens() async throws {
    let db = try await makeShippedDatabase()
    let repository = makeRepository(db)
    var stored = HealthProfile.default
    stored.allergenIngredientIds = "[3,6,7,21,38,47]"
    try UserDataRepository(db: db).saveHealthProfile(stored)

    let unrestricted = try XCTUnwrap(
      try repository.quickSuggestion(with: pantry, profile: .default),
      "the pantry must yield a suggestion for an unrestricted household")
    let screened = try repository.quickSuggestion(with: pantry, profile: stored)
    XCTAssertNotEqual(
      screened?.recipe.title, unrestricted.recipe.title,
      "flagging every pantry ingredient must change the suggestion, or this test proves nothing")

    let generator = FallbackRecipeGenerator(
      recipeRepository: repository, ingredientResolver: NumericIDResolver())
    let generated = try await generator.generate(
      from: pantry.map(String.init), dietaryRestrictions: [])

    XCTAssertEqual(generated?.title, screened?.recipe.title)
  }

  func testFallbackRefusesWhenTheProfileCannotBeRead() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try await db.write { try $0.execute(sql: "DROP TABLE health_profile") }
    let generator = FallbackRecipeGenerator(
      recipeRepository: makeRepository(db), ingredientResolver: NumericIDResolver())

    do {
      let generated = try await generator.generate(
        from: pantry.map(String.init), dietaryRestrictions: [])
      XCTFail("expected the profile read to throw, got \(String(describing: generated?.title))")
    } catch {}
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
}

/// Resolves "38" to ingredient 38, so the test controls exactly which ids the generator sees.
private struct NumericIDResolver: IngredientCatalogResolving {
  func resolve(_ rawValue: String, matching: IngredientCatalogMatching) -> Int64? {
    Int64(rawValue)
  }
  func resolveFromText(_ rawText: String) -> Int64? { Int64(rawText) }
  func displayName(for ingredientId: Int64) -> String? { nil }
}
