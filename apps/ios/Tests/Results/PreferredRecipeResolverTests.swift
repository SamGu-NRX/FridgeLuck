import XCTest

@testable import FridgeLuck

/// The resolver maps an incoming preferred identity — a Home card, a demo scenario, a
/// replay — to the exact scored result: the legacy id when the entry has one, the
/// catalog ref when it does not. Catalog entries carry `Recipe(id: nil, …)`, so identity
/// can never ride the integer column alone.
final class PreferredRecipeResolverTests: XCTestCase {
  private func fixture(
    id: Int64?,
    title: String,
    catalogID: String? = nil
  ) -> ScoredRecipe {
    var scored = ScoredRecipe(
      recipe: Recipe(
        id: id,
        title: title,
        timeMinutes: 10,
        servings: 2,
        instructions: "Cook.",
        tags: 0,
        source: .bundled,
        createdAt: nil),
      matchedRequired: 1,
      totalRequired: 1,
      matchedOptional: 0,
      missingRequiredCount: 0,
      missingIngredientIds: [],
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10,
        fatPerServing: 3, fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 50),
      healthScore: HealthScore(rating: 4, label: "Good", reasoning: "test"),
      personalScore: 0.5,
      rankingScore: 1.0,
      rankingReasons: [],
      matchTier: .exact)
    if let catalogID {
      scored.catalog = CatalogRecipeMatch(
        ref: .catalog(id: catalogID, revision: 1), successorToLegacyRecipeID: nil)
    }
    return scored
  }

  func testNilPreferredPresentsNothing() {
    let results = [fixture(id: 1, title: "Legacy")]
    XCTAssertNil(PreferredRecipeResolver.resolve(preferredID: nil, in: results))
  }

  func testLegacyIdentityResolvesByIntegerID() {
    let legacy = fixture(id: 7, title: "Legacy Pancakes")
    let catalog = fixture(id: nil, title: "Catalog Pancakes", catalogID: "rcp-000123")
    let resolved = PreferredRecipeResolver.resolve(
      preferredID: .legacy(7), in: [catalog, legacy])
    XCTAssertEqual(resolved?.id, .legacy(7))
    XCTAssertEqual(resolved?.recipe.title, "Legacy Pancakes")
  }

  func testCatalogIdentityResolvesByRefWhenRecipeIDIsNil() {
    let legacy = fixture(id: 7, title: "Legacy Pancakes")
    let catalog = fixture(id: nil, title: "Catalog Pancakes", catalogID: "rcp-000123")
    let resolved = PreferredRecipeResolver.resolve(
      preferredID: .catalog("rcp-000123"), in: [legacy, catalog])
    XCTAssertEqual(resolved?.id, .catalog("rcp-000123"))
    XCTAssertEqual(resolved?.recipe.title, "Catalog Pancakes")
  }

  func testUnmatchedIdentityReturnsNil() {
    let results = [fixture(id: 7, title: "Legacy Pancakes")]
    XCTAssertNil(PreferredRecipeResolver.resolve(preferredID: .legacy(8), in: results))
    XCTAssertNil(
      PreferredRecipeResolver.resolve(preferredID: .catalog("rcp-404"), in: results))
  }

  func testFirstMatchWinsOnDuplicateIdentities() {
    let first = fixture(id: 7, title: "First")
    let second = fixture(id: 7, title: "Second")
    let resolved = PreferredRecipeResolver.resolve(
      preferredID: .legacy(7), in: [first, second])
    XCTAssertEqual(resolved?.recipe.title, "First")
  }
}
