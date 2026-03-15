import Foundation
import XCTest

final class GeminiLiveTutorialFlowTests: XCTestCase {
  private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testTutorialQuestSourceDefinesFiveStepFlowIncludingLiveAgent() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("Feature/Home/TutorialQuestModels.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("case firstScan = 0"))
    XCTAssertTrue(source.contains("case ingredientReview = 1"))
    XCTAssertTrue(source.contains("case pickRecipeMatch = 2"))
    XCTAssertTrue(source.contains("case liveAgent = 3"))
    XCTAssertTrue(source.contains("case cookAndRate = 4"))
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

  func testContentViewRoutesHomeToAssistantAndTutorialCook() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains(".navigationDestination(item: $assistantRecipeContext)"))
    XCTAssertTrue(source.contains(".fullScreenCover(item: $tutorialCookingRecipe)"))
    XCTAssertTrue(source.contains("markTutorialQuest(.liveAgent)"))
  }

  func testPackageManifestIncludesIntegrationSources() throws {
    let source = try String(
      contentsOf: packageRoot().appendingPathComponent("Package.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("\"Integration\""))
  }
}
