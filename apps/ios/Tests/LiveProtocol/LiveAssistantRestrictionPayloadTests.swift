import XCTest

@testable import FridgeLuck

@MainActor
final class LiveAssistantRestrictionPayloadTests: XCTestCase {
  func testSnapshotCarriesHouseholdRestrictions() {
    let cook = CookModeViewModel(
      recipe: Recipe(
        id: 1, title: "Noodles", timeMinutes: 10, servings: 2, instructions: "1. Cook",
        tags: 0, source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .ephemeral())
    let payload = LiveAssistantViewModel.boundedSnapshot(
      from: cook, restrictions: ["peanut", "vegan"])
    let cookSession = payload["cookSession"] as? [String: Any]
    let eaters = cookSession?["eaters"] as? [[String: Any]]
    XCTAssertEqual(eaters?.first?["restrictions"] as? [String], ["peanut", "vegan"])
  }
}
