import Foundation
import XCTest

final class GeminiLiveTutorialFlowTests: XCTestCase {
  private func iosRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func repoRoot() -> URL {
    iosRoot()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testTutorialQuestSourceDefinesFourStepFlowIncludingCookWithLeChef() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Home/TutorialQuestModels.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("case firstScan = 0"))
    XCTAssertTrue(source.contains("case ingredientReview = 1"))
    XCTAssertTrue(source.contains("case pickRecipeMatch = 2"))
    XCTAssertTrue(source.contains("case cookWithLeChef = 3"))
  }

  func testRecipeResultsPromotesRecipeSelectionIntoLiveAssistantLesson() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Results/RecipeResultsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("liveAssistantCoordinator.storeRecipeMatch"))
    XCTAssertTrue(source.contains("context.completeObjective()"))
    XCTAssertTrue(source.contains("didPromoteRecipeMatchLesson = true"))
    XCTAssertTrue(source.contains("selectedRecipe = scored"))
  }

  func testContentViewUsesLiveAssistantAsOnlyCookingRoute() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains(".navigationDestination(item: $assistantRecipeContext)"))
    XCTAssertFalse(source.contains("tutorialCookingRecipe"))
    XCTAssertTrue(source.contains("markTutorialQuest(.cookWithLeChef)"))
  }

  func testXcodeGenProjectIncludesIntegrationSources() throws {
    let source = try String(
      contentsOf: repoRoot().appendingPathComponent("project.yml"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("- path: apps/ios/Integration"))
  }
}
