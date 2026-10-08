import SwiftUI
import XCTest

@testable import FridgeLuck

/// The tour's Skip button must sit below the top safe area. On a pushed screen that area holds
/// the navigation bar, which takes every tap there (2026-10-07 walk, Review Ingredients).
final class SpotlightSkipLayoutTests: XCTestCase {
  // iPhone 17 points: 62 pt status bar; a pushed screen adds a 54 pt inline navigation bar.
  private let screen = CGSize(width: 402, height: 874)
  private let homeInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
  private let pushedInsets = EdgeInsets(top: 116, leading: 0, bottom: 34, trailing: 0)
  private let centeredTooltip = CGRect(x: 31, y: 307, width: 340, height: 260)

  func testTopPlacementsStartBelowThePushedNavigationBar() {
    for placement in [SpotlightSkipLayout.Placement.topTrailing, .topLeading] {
      let frame = SpotlightSkipLayout.frame(
        for: placement, containerSize: screen, safeAreaInsets: pushedInsets)
      XCTAssertGreaterThanOrEqual(frame.minY, pushedInsets.top, "\(placement)")
    }
  }

  func testHomeKeepsItsOriginalTopOffset() {
    let frame = SpotlightSkipLayout.frame(
      for: .topTrailing, containerSize: screen, safeAreaInsets: homeInsets)
    XCTAssertEqual(frame.minY, 88)
    XCTAssertEqual(frame.maxX, screen.width - AppTheme.Space.page)
  }

  func testTopOffsetLeavesAGapBelowTallTopBars() {
    XCTAssertEqual(
      SpotlightSkipLayout.topOffset(safeAreaTop: 116), 116 + SpotlightSkipLayout.gapBelowTopBar)
    XCTAssertEqual(SpotlightSkipLayout.topOffset(safeAreaTop: 0), 88)
  }

  func testPrefersTopTrailingWhenNothingCoversIt() {
    let placement = SpotlightSkipLayout.placement(
      containerSize: screen, safeAreaInsets: pushedInsets,
      tooltipFrame: centeredTooltip, highlightFrame: nil)
    XCTAssertEqual(placement, .topTrailing)
  }

  /// The toolbar-add step highlights the + button inside the navigation bar. Skip now sits
  /// below the bar, so it no longer has to move away from that highlight.
  func testToolbarHighlightInsideTheBarDoesNotDisplaceSkip() {
    let toolbarHighlight = CGRect(x: 330, y: 66, width: 72, height: 44)
    let placement = SpotlightSkipLayout.placement(
      containerSize: screen, safeAreaInsets: pushedInsets,
      tooltipFrame: centeredTooltip, highlightFrame: toolbarHighlight)
    XCTAssertEqual(placement, .topTrailing)
  }

  func testFallsBackToTopLeadingWhenTheHighlightCoversTopTrailing() {
    let trailingHighlight = CGRect(x: 250, y: 110, width: 140, height: 80)
    let placement = SpotlightSkipLayout.placement(
      containerSize: screen, safeAreaInsets: pushedInsets,
      tooltipFrame: centeredTooltip, highlightFrame: trailingHighlight)
    XCTAssertEqual(placement, .topLeading)
  }

  func testFallsBackToBottomLeadingAboveTheHomeIndicatorWhenTheTopIsCovered() {
    let topTooltip = CGRect(x: 31, y: 100, width: 340, height: 260)
    let placement = SpotlightSkipLayout.placement(
      containerSize: screen, safeAreaInsets: pushedInsets,
      tooltipFrame: topTooltip, highlightFrame: nil)
    XCTAssertEqual(placement, .bottomLeading)

    let frame = SpotlightSkipLayout.frame(
      for: .bottomLeading, containerSize: screen, safeAreaInsets: pushedInsets)
    XCTAssertLessThanOrEqual(frame.maxY, screen.height - pushedInsets.bottom)
  }
}
