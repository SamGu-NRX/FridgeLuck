import Foundation
import XCTest

final class SpotlightAnchorUpdateTests: XCTestCase {
  private func sourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testSpotlightCoordinatorNormalizesAndDefersAnchorUpdates() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/SpotlightTutorialOverlay.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("func updateAnchors("))
    XCTAssertTrue(source.contains("retainingExistingValues: Bool = false"))
    XCTAssertTrue(source.contains("let normalizedRect = rect.normalizedForSpotlight"))
    XCTAssertTrue(source.contains("Task { @MainActor"))
  }

  func testHighlightRectUsesOverlayLocalCoordinatesOnly() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/SpotlightTutorialOverlay.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("let overlayFrame = geo.frame(in: .global)"))
    XCTAssertTrue(source.contains("return CGRect("))
    XCTAssertFalse(source.contains("return globalRect"))
    XCTAssertFalse(source.contains("visibleIntersectionArea("))
    XCTAssertFalse(source.contains("let normalizedScore"))
    XCTAssertFalse(source.contains("let globalScore"))
  }

  func testSpotlightScreensUseCoordinatorAnchorUpdateHelper() throws {
    let root = sourceRoot()
    let ingredientReview = try String(
      contentsOf: root.appendingPathComponent("Feature/Ingredients/IngredientReviewView.swift"),
      encoding: .utf8
    )
    let home = try String(
      contentsOf: root.appendingPathComponent("Feature/Home/HomeDashboardView.swift"),
      encoding: .utf8
    )
    let demo = try String(
      contentsOf: root.appendingPathComponent("Feature/Demo/DemoModeView.swift"),
      encoding: .utf8
    )
    let recipePreview = try String(
      contentsOf: root.appendingPathComponent("Feature/Recipe/RecipePreviewDrawer.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(ingredientReview.contains("reviewSpotlight.updateAnchors(newAnchors"))
    XCTAssertTrue(home.contains("spotlightCoordinator.updateAnchors($0)"))
    XCTAssertTrue(demo.contains("demoSpotlight.updateAnchors($0)"))
    XCTAssertTrue(recipePreview.contains("swapSpotlight.updateAnchors($0)"))
  }
}
