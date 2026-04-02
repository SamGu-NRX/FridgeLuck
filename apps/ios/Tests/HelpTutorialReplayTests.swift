import Foundation
import XCTest

@testable import FridgeLuck

final class HelpTutorialReplayTests: XCTestCase {
  func testHelpTutorialReplayRouteMapsEachQuestToExpectedDestination() {
    XCTAssertEqual(HelpTutorialReplayRoute.route(for: .firstScan), .demoMode)
    XCTAssertEqual(
      HelpTutorialReplayRoute.route(for: .ingredientReview),
      .ingredientReview(.asianStirFry)
    )
    XCTAssertEqual(
      HelpTutorialReplayRoute.route(for: .pickRecipeMatch),
      .recipeMatch(.mediterraneanLunch)
    )
    XCTAssertEqual(
      HelpTutorialReplayRoute.route(for: .cookWithLeChef),
      .liveAssistant(.mediterraneanLunch)
    )
  }

  func testSettingsHelpViewRoutesQuestCardsThroughReplayCallback() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Settings/SettingsHelpView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("let onReplayQuest: (TutorialQuest) -> Void"))
    XCTAssertTrue(source.contains("Button(action: { onReplayQuest(quest) })"))
  }

  func testContentViewHelpReplayPathAvoidsQuestProgressSideEffects() throws {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent("App/ContentView.swift"),
      encoding: .utf8
    )
    let replayFunction = try XCTUnwrap(
      extractFunctionBody(named: "replayHelpTutorial", from: source)
    )

    XCTAssertTrue(replayFunction.contains("settingsCoordinator.reset()"))
    XCTAssertTrue(replayFunction.contains("tutorialFlowContext.reset()"))
    XCTAssertTrue(replayFunction.contains("returnToHomeRoot()"))
    XCTAssertTrue(replayFunction.contains("HelpTutorialReplayRoute.route(for: quest)"))
    XCTAssertFalse(replayFunction.contains("tutorialFlowContext.beginQuest"))
    XCTAssertFalse(replayFunction.contains("markTutorialQuest"))
  }

  func testReplaySpotlightHooksExistForAllReplayDestinations() throws {
    let demoSource = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Demo/DemoModeView.swift"),
      encoding: .utf8
    )
    let reviewSource = try String(
      contentsOf: iosRoot().appendingPathComponent(
        "Feature/Ingredients/IngredientReviewView.swift"),
      encoding: .utf8
    )
    let resultsSource = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Results/RecipeResultsView.swift"),
      encoding: .utf8
    )
    let assistantSource = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Assistant/LiveAssistantView.swift"),
      encoding: .utf8
    )
    let spotlightSource = try String(
      contentsOf: iosRoot().appendingPathComponent("Feature/Home/SpotlightModels.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(demoSource.contains("presentDemoSpotlight(markSeen: !replaySpotlightPending)"))
    XCTAssertTrue(
      reviewSource.contains("presentReviewSpotlight(markSeen: !replaySpotlightPending)")
    )
    XCTAssertTrue(resultsSource.contains("SpotlightStep.recipeMatchReplay"))
    XCTAssertTrue(assistantSource.contains("SpotlightStep.liveCookReplay"))
    XCTAssertTrue(spotlightSource.contains("static let recipeMatchReplay"))
    XCTAssertTrue(spotlightSource.contains("static let liveCookReplay"))
  }

  private func iosRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func extractFunctionBody(named name: String, from source: String) -> String? {
    guard let startRange = source.range(of: "private func \(name)") else { return nil }
    let suffix = source[startRange.lowerBound...]
    guard let endRange = suffix.range(of: "\n  private func ", options: []) else {
      return String(suffix)
    }
    return String(suffix[..<endRange.lowerBound])
  }
}
