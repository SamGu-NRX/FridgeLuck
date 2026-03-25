import FLFeatureLogic
import XCTest

final class RecommendationPolicyTests: XCTestCase {
  func testEffectiveIngredientIDsUsesFallbackWhenInputIsEmpty() {
    XCTAssertEqual(
      RecommendationPolicy.effectiveIngredientIDs(from: []),
      RecommendationPolicy.fallbackIngredientIDs
    )
  }

  func testEffectiveIngredientIDsPreservesDetectedIngredients() {
    XCTAssertEqual(
      RecommendationPolicy.effectiveIngredientIDs(from: [10, 20]),
      [10, 20]
    )
  }

  func testNearMatchLimitUsesExpandedLimitWhenNoExactMatches() {
    XCTAssertEqual(RecommendationPolicy.nearMatchLimit(hasExactMatches: false), 20)
  }

  func testNearMatchLimitUsesCondensedLimitWhenExactMatchesExist() {
    XCTAssertEqual(RecommendationPolicy.nearMatchLimit(hasExactMatches: true), 8)
  }

  func testShouldWidenNearMatchSearchWhenNoRecommendationsExist() {
    XCTAssertTrue(RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 0, nearMatchCount: 0))
  }

  func testShouldNotWidenNearMatchSearchWhenAnyRecommendationExists() {
    XCTAssertFalse(
      RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 1, nearMatchCount: 0)
    )
    XCTAssertFalse(
      RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 0, nearMatchCount: 1)
    )
  }
}
