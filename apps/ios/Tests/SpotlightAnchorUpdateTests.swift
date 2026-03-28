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

    XCTAssertTrue(source.contains("struct SpotlightPresentation"))
    XCTAssertTrue(source.contains("var activePresentation: SpotlightPresentation? = nil"))
    XCTAssertTrue(source.contains("func dismissActivePresentation()"))
    XCTAssertTrue(source.contains("onDismissPresentation?(activePresentation)"))
    XCTAssertTrue(source.contains("func updateAnchors("))
    XCTAssertTrue(source.contains("retainingExistingValues: Bool = false"))
    XCTAssertTrue(source.contains("let normalizedRect = entry.value.normalizedForSpotlight"))
    XCTAssertTrue(source.contains("var nextAnchors = retainingExistingValues ? self.anchors : [:]"))
    XCTAssertFalse(source.contains("private var anchorUpdateGeneration = 0"))
    XCTAssertFalse(source.contains("self.anchorUpdateGeneration == generation"))
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

  func testSpotlightOverlayUsesSimpleEntranceAndFixedTooltipPlacement() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/SpotlightTutorialOverlay.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("@State private var appeared = false"))
    XCTAssertTrue(source.contains(".opacity(appeared ? 1 : 0)"))
    XCTAssertTrue(source.contains("await Task.yield()"))
    XCTAssertTrue(source.contains("AppMotion.spotlightDimmer"))
    XCTAssertTrue(source.contains("AppMotion.spotlightCardEntry"))
    XCTAssertTrue(source.contains(".scaleEffect(appeared ? 1.0 : 0.96)"))
    XCTAssertTrue(source.contains(".offset(y: appeared ? 0 : 8)"))
    XCTAssertTrue(source.contains(".onChange(of: presentationID)"))
    XCTAssertTrue(source.contains("private let tooltipCardHeight: CGFloat = 260"))
    XCTAssertTrue(source.contains("private let skipTopOffset: CGFloat = 88"))
    XCTAssertTrue(source.contains("private let skipBottomOffset: CGFloat = 24"))
    XCTAssertFalse(source.contains("dimmerVisible"))
    XCTAssertFalse(source.contains("cardVisible"))
    XCTAssertFalse(source.contains("hasStartedEntrance"))
    XCTAssertFalse(source.contains("tooltipCardSize"))
    XCTAssertFalse(source.contains(".onGeometryChange(for: CGSize.self)"))
  }

  func testSpotlightOverlayUsesCollisionAwareSkipPlacement() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/SpotlightTutorialOverlay.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("private enum SkipButtonPlacement"))
    XCTAssertTrue(source.contains("case topTrailing"))
    XCTAssertTrue(source.contains("case topLeading"))
    XCTAssertTrue(source.contains("case bottomLeading"))
    XCTAssertTrue(source.contains("private func skipButtonPlacement(in geo: GeometryProxy)"))
    XCTAssertTrue(source.contains("if skipFrame.intersects(tooltipFrame)"))
    XCTAssertTrue(source.contains("if let highlightFrame, skipFrame.intersects(highlightFrame)"))
    XCTAssertTrue(source.contains("return .bottomLeading"))
  }

  func testSpotlightOverlayKeepsTimedAnchoredTransitions() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/SpotlightTutorialOverlay.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(
      source.contains("let stepDelay: Double = needsScroll && !reduceMotion ? 0.25 : 0"))
    XCTAssertTrue(source.contains("DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay)"))
    XCTAssertFalse(source.contains("onScrollToAnchorAndWait"))
    XCTAssertFalse(source.contains("private func transition(to targetIndex: Int)"))
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
    let ingredientSections = try String(
      contentsOf: root.appendingPathComponent("Feature/Ingredients/IngredientReviewSections.swift"),
      encoding: .utf8
    )
    let recipePreview = try String(
      contentsOf: root.appendingPathComponent("Feature/Recipe/RecipePreviewDrawer.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(ingredientReview.contains("reviewSpotlight.updateAnchors(newAnchors"))
    XCTAssertTrue(home.contains("spotlightCoordinator.updateAnchors($0)"))
    XCTAssertTrue(demo.contains("demoSpotlight.updateAnchors($0)"))
    XCTAssertTrue(ingredientSections.contains(".id(\"findRecipes\")"))
    XCTAssertTrue(ingredientSections.contains(".spotlightAnchor(\"findRecipes\")"))
    XCTAssertTrue(recipePreview.contains("swapSpotlight.updateAnchors($0)"))
    XCTAssertTrue(
      demo.contains(".navigationBarBackButtonHidden(isOverlayVisible || showDemoSpotlight)"))
  }

  func testIngredientReviewUsesTighterAnchorScopes() throws {
    let source = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Ingredients/IngredientReviewView.swift"),
      encoding: .utf8
    )
    let sections = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Ingredients/IngredientReviewSections.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("guard anchorID != \"confidenceLevels\" else { return }"))
    XCTAssertTrue(source.contains("scrollProxy.scrollTo(anchorID, anchor: .center)"))
    XCTAssertTrue(source.contains("presentReviewSpotlight()"))
    XCTAssertFalse(source.contains("reviewScrollPhase"))
    XCTAssertFalse(source.contains("isPreparingReviewSpotlight"))
    XCTAssertFalse(source.contains(".onScrollPhaseChange"))
    XCTAssertFalse(source.contains("prepareReviewSpotlight()"))
    XCTAssertFalse(source.contains("presentPreparedReviewSpotlightIfReady()"))
    XCTAssertFalse(
      source.contains(".id(\"bulkActions\")\n              .spotlightAnchor(\"bulkActions\")"))
    XCTAssertFalse(source.contains(".id(\"findRecipes\")\n      .spotlightAnchor(\"findRecipes\")"))
    XCTAssertTrue(source.contains(".id(\"bulkActions\")"))
    XCTAssertTrue(source.contains(".spotlightAnchor(\"bulkActions\")"))
    XCTAssertTrue(sections.contains(".id(\"findRecipes\")"))
    XCTAssertTrue(sections.contains(".spotlightAnchor(\"findRecipes\")"))
  }

  func testSpotlightHostsWaitForVisibleScreenState() throws {
    let home = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Home/HomeDashboardView.swift"),
      encoding: .utf8
    )
    let demo = try String(
      contentsOf: sourceRoot().appendingPathComponent(
        "Feature/Demo/DemoModeView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(
      home.contains("return heroAppeared && anchorsReady(for: .onboarding) ? .onboarding : nil"))
    XCTAssertTrue(
      home.contains("return heroAppeared && anchorsReady(for: .questAdvance) ? .questAdvance : nil")
    )
    XCTAssertTrue(demo.contains("private var shouldAutoPresentDemoSpotlight: Bool"))
    XCTAssertTrue(demo.contains("guard appeared else { return false }"))
    XCTAssertTrue(demo.contains(".task(id: shouldAutoPresentDemoSpotlight)"))
  }
}
