import XCTest

@testable import FridgeLuck

/// Cloud ranking keys every round trip on an integer `recipe_id`. Legacy candidates ride
/// their real positive id; catalog candidates — `Recipe(id: nil, …)` — ride a negative
/// alias derived from list position. The two spaces cannot collide, and the agent and
/// the service both read the rule from `ReverseScanCandidateHandle`, so a ranking can
/// never map back to the wrong candidate.
final class ReverseScanCandidateHandleTests: XCTestCase {
  private func candidate(id: Int64?, title: String, catalogID: String? = nil)
    -> ReverseScanRecipeCandidate
  {
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
    return ReverseScanRecipeCandidate(
      recipe: scored, confidenceScore: 0.5, matchedDetectedIngredients: 1, explanation: nil)
  }

  func testLegacyCandidatesKeepTheirPositiveID() {
    let handles = ReverseScanCandidateHandle.handles(for: [
      candidate(id: 12, title: "A"), candidate(id: 345, title: "B"),
    ])
    XCTAssertEqual(handles, [12, 345])
  }

  func testCatalogCandidatesRideNegativeAliasesInOrder() {
    let handles = ReverseScanCandidateHandle.handles(for: [
      candidate(id: nil, title: "First", catalogID: "rcp-000001"),
      candidate(id: nil, title: "Second", catalogID: "rcp-000002"),
    ])
    XCTAssertEqual(handles, [-1, -2])
  }

  func testMixedListKeepsBothSpacesDisjoint() {
    let handles = ReverseScanCandidateHandle.handles(for: [
      candidate(id: 1, title: "Legacy 1"),
      candidate(id: nil, title: "Catalog", catalogID: "rcp-000009"),
      candidate(id: 2, title: "Legacy 2"),
      candidate(id: nil, title: "Draft"),  // unsaved generated draft: negative alias too
    ])
    XCTAssertEqual(handles, [1, -1, 2, -2])
  }

  func testNegativeAliasesNeverCollideWithLegacyIDs() {
    // Legacy ids are row keys — always positive — so a mixed list can never send the
    // same handle twice with different identities.
    let handles = ReverseScanCandidateHandle.handles(for: [
      candidate(id: 1, title: "Legacy"),
      candidate(id: nil, title: "Catalog A", catalogID: "rcp-000001"),
      candidate(id: nil, title: "Catalog B", catalogID: "rcp-000002"),
    ])
    XCTAssertEqual(Set(handles).count, handles.count)
    XCTAssertTrue(handles.allSatisfy { $0 != 0 })
  }

  func testEmptyListProducesNoHandles() {
    XCTAssertTrue(ReverseScanCandidateHandle.handles(for: []).isEmpty)
  }
}
