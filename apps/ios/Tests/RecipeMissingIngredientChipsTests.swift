import FLFeatureLogic
import XCTest

@testable import FridgeLuck

/// With no exact matches, the first near match becomes the Best Match hero and leaves
/// "Almost there", so the hero has to name its missing ingredients itself.
final class RecipeMissingIngredientChipsTests: XCTestCase {
  func testNearMatchHeroNamesEachMissingIngredientInOrder() throws {
    let sections = RecommendationSections(
      exact: [],
      nearMatch: [
        scored(1, missing: [line("Cucumber", [41]), line("Noodles", [42])]),
        scored(2, missing: [line("Noodles", [42])]),
      ])
    let hero = try XCTUnwrap(sections.bestMatch)

    XCTAssertEqual(RecipeMissingIngredientChips.names(for: hero), ["Cucumber", "Noodles"])
  }

  /// A catalog line bridged to three app ingredients is one missing ingredient, named once.
  func testLineStandingForSeveralIngredientsIsOneChip() {
    let hero = scored(1, missing: [line("Green onion", [21, 170_005, 170_006])])
    XCTAssertEqual(RecipeMissingIngredientChips.names(for: hero), ["Green onion"])
    XCTAssertEqual(RecipeMissingIngredientChips.names(for: hero).count, hero.missingRequiredCount)
  }

  func testExactMatchHeroShowsNoMissingChips() {
    XCTAssertEqual(RecipeMissingIngredientChips.names(for: scored(1, missing: [])), [])
  }

  private func line(_ name: String, _ ids: [Int64]) -> MissingRequiredLine {
    MissingRequiredLine(name: name, ingredientIDs: ids)
  }

  private func scored(_ id: Int64, missing: [MissingRequiredLine]) -> ScoredRecipe {
    ScoredRecipe(
      recipe: Recipe(
        id: id, title: "Recipe \(id)", timeMinutes: 10, servings: 1, instructions: "Cook.",
        tags: 0, source: .bundled, createdAt: nil),
      matchedRequired: 1,
      totalRequired: 1 + missing.count,
      matchedOptional: 0,
      missingRequiredCount: missing.count,
      missingIngredientIds: missing.flatMap(\.ingredientIDs),
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
        fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
      healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
      personalScore: 0,
      rankingScore: 0,
      rankingReasons: [],
      matchTier: missing.isEmpty ? .exact : .nearMatch,
      missingRequiredLines: missing
    )
  }
}
