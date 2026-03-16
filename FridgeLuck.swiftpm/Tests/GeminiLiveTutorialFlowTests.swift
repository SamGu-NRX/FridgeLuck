import Foundation
import XCTest

final class GeminiLiveTutorialFlowTests: XCTestCase {
  private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testTutorialQuestSourceDefinesFourStepFlowIncludingCookWithLeChef() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("Feature/Home/TutorialQuestModels.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("case firstScan = 0"))
    XCTAssertTrue(source.contains("case ingredientReview = 1"))
    XCTAssertTrue(source.contains("case pickRecipeMatch = 2"))
    XCTAssertTrue(source.contains("case cookWithLeChef = 3"))
  }

  func testRecipeResultsPromotesRecipeSelectionIntoLiveAssistantLesson() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("Feature/Results/RecipeResultsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("liveAssistantCoordinator.storeRecipeMatch"))
    XCTAssertTrue(source.contains("progress.markCompleted(.pickRecipeMatch)"))
    XCTAssertTrue(source.contains("navCoordinator.returnHome()"))
  }

  func testContentViewUsesLiveAssistantAsOnlyCookingRoute() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains(".navigationDestination(item: $assistantRecipeContext)"))
    XCTAssertFalse(source.contains("tutorialCookingRecipe"))
    XCTAssertTrue(source.contains("markTutorialQuest(.cookWithLeChef)"))
  }

  func testPackageManifestIncludesIntegrationSources() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("\"Integration\""))
  }
}
