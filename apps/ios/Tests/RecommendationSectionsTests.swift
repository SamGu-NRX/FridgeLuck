import XCTest

@testable import FridgeLuck

/// The Best Match hero must not repeat in the lists below it (2026-10-07 walk: the hero also
/// appeared under "Almost there").
final class RecommendationSectionsTests: XCTestCase {
  func testNearMatchHeroIsLeftOutOfAlmostThere() {
    let sections = RecommendationSections(
      exact: [], nearMatch: [scored(1, .nearMatch), scored(2, .nearMatch)])

    XCTAssertEqual(sections.bestMatch?.recipe.id, 1)
    XCTAssertEqual(sections.belowBestMatch.nearMatch.map(\.recipe.id), [2])
  }

  func testExactHeroIsLeftOutOfTheGridAndNearMatchesStay() {
    let sections = RecommendationSections(
      exact: [scored(1, .exact), scored(2, .exact)], nearMatch: [scored(3, .nearMatch)])

    XCTAssertEqual(sections.bestMatch?.recipe.id, 1)
    XCTAssertEqual(sections.belowBestMatch.exact.map(\.recipe.id), [2])
    XCTAssertEqual(sections.belowBestMatch.nearMatch.map(\.recipe.id), [3])
  }

  func testSingleResultLeavesNothingBelowTheHero() {
    let sections = RecommendationSections(exact: [], nearMatch: [scored(1, .nearMatch)])

    XCTAssertTrue(sections.belowBestMatch.isEmpty)
    XCTAssertFalse(sections.isEmpty)
  }

  func testEmptySectionsHaveNoHero() {
    XCTAssertNil(RecommendationSections.empty.bestMatch)
    XCTAssertTrue(RecommendationSections.empty.belowBestMatch.isEmpty)
  }

  private func scored(_ id: Int64, _ tier: RecipeMatchTier) -> ScoredRecipe {
    ScoredRecipe(
      recipe: Recipe(
        id: id, title: "Recipe \(id)", timeMinutes: 10, servings: 1, instructions: "Cook.",
        tags: 0, source: .bundled, createdAt: nil),
      matchedRequired: 1,
      totalRequired: tier == .exact ? 1 : 2,
      matchedOptional: 0,
      missingRequiredCount: tier == .exact ? 0 : 1,
      missingIngredientIds: tier == .exact ? [] : [99],
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
        fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
      healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
      personalScore: 0,
      rankingScore: 0,
      rankingReasons: [],
      matchTier: tier
    )
  }
}
