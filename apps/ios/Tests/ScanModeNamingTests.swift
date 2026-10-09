import XCTest
@testable import FridgeLuck

/// The meal-photo flow is reachable from several entry points (the scan-mode fan menu and the
/// Progress and Dashboard buttons), so they must share one plain, user-facing name. Internal
/// "reverse scan" jargon must not leak back into user-facing labels.
final class ScanModeNamingTests: XCTestCase {
  func testLogMealModeKeepsPlainName() {
    XCTAssertEqual(ScanMode.logMeal.label, "Log a Meal")
  }

  func testLogMealModeUsesFoodSymbol() {
    XCTAssertEqual(ScanMode.logMeal.icon, "fork.knife")
  }

  func testNoScanModeLabelContainsReverseScanJargon() {
    for mode in ScanMode.allCases {
      XCTAssertFalse(
        mode.label.lowercased().contains("reverse"),
        "\(mode.rawValue) label \"\(mode.label)\" uses internal reverse-scan jargon."
      )
    }
  }

  func testNoScanModeUsesFlowerIcon() {
    for mode in ScanMode.allCases {
      XCTAssertFalse(
        mode.icon.contains("camera.macro"),
        "\(mode.rawValue) uses camera.macro, which reads as a flower."
      )
    }
  }
}
