import XCTest

@testable import FridgeLuck

/// With no exact matches, the first near match becomes the Best Match hero and leaves
/// "Almost there", so the hero has to name its missing ingredients itself.
final class RecipeMissingIngredientChipsTests: XCTestCase {
  private let names: [Int64: String] = [41: "Cucumber", 42: "Noodles"]

  func testNearMatchHeroNamesEachMissingIngredientInOrder() throws {
    let sections = RecommendationSections(
      exact: [], nearMatch: [scored(1, missing: [41, 42]), scored(2, missing: [42])])
    let hero = try XCTUnwrap(sections.bestMatch)

    XCTAssertEqual(
      RecipeMissingIngredientChips.names(for: hero, displayName: { self.names[$0] ?? "?" }),
      ["Cucumber", "Noodles"])
  }

  func testExactMatchHeroShowsNoMissingChips() {
    XCTAssertEqual(
      RecipeMissingIngredientChips.names(for: scored(1, missing: []), displayName: { _ in "?" }),
      [])
  }

  private func scored(_ id: Int64, missing: [Int64]) -> ScoredRecipe {
    ScoredRecipe(
      recipe: Recipe(
        id: id, title: "Recipe \(id)", timeMinutes: 10, servings: 1, instructions: "Cook.",
        tags: 0, source: .bundled, createdAt: nil),
      matchedRequired: 1,
      totalRequired: 1 + missing.count,
      matchedOptional: 0,
      missingRequiredCount: missing.count,
      missingIngredientIds: missing,
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
        fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
      healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
      personalScore: 0,
      rankingScore: 0,
      rankingReasons: [],
      matchTier: missing.isEmpty ? .exact : .nearMatch
    )
  }
}
