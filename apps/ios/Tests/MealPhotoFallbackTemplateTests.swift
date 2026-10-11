import XCTest

@testable import FridgeLuck

/// The meal-photo fallback names a dish only when a detected ingredient points at it.
final class MealPhotoFallbackTemplateTests: XCTestCase {
  /// Same names and order as the bundled templates (`DishEstimateService.templates()` sorts by
  /// name), so "Curry" comes first, as it did when the walk offered it for fried rice.
  private let templates = [
    "Curry", "Fried Rice", "Pasta Bowl", "Sandwich", "Soup Bowl", "Stir Fry",
  ].map {
    DishTemplate(
      id: nil, name: $0, baseCalories: 400, baseProtein: 10, baseCarbs: 40, baseFat: 10)
  }

  private func pick(_ labels: [String]) -> String? {
    ReverseScanService.fallbackTemplate(from: templates, detectionLabels: labels)?.name
  }

  func testNoDetectionsNamesNoDish() {
    XCTAssertNil(pick([]))
  }

  func testUnrelatedDetectionsNameNoDish() {
    XCTAssertNil(pick(["Cheese", "Black Beans"]))
  }

  func testRiceDetectionPicksFriedRice() {
    XCTAssertEqual(pick(["Cooked Rice"]), "Fried Rice")
  }

  func testCoconutDetectionPicksCurry() {
    XCTAssertEqual(pick(["Coconut Milk"]), "Curry")
  }

  func testStrongerEvidenceWinsOverWeaker() {
    // Rice scores 6 for fried rice; bread scores 5 for sandwich.
    XCTAssertEqual(pick(["Bread", "Rice"]), "Fried Rice")
  }

  func testNoTemplatesNamesNoDish() {
    XCTAssertNil(ReverseScanService.fallbackTemplate(from: [], detectionLabels: ["Rice"]))
  }
}
