import Foundation
import XCTest

/// Regression tests for the meal-photo capture hero: the illustration must show the
/// ordinary camera symbol, and stay out of the VoiceOver order so it never announces
/// a second capture action next to the real buttons below it.
final class ReverseScanMealCaptureIconTests: XCTestCase {
  func testCaptureHeroUsesPlainCameraSymbolInsteadOfMacroFlower() throws {
    let hero = try captureHeroSource()

    XCTAssertTrue(hero.contains("Image(systemName: \"camera\")"))
    XCTAssertFalse(hero.contains("camera.macro"))
  }

  func testCaptureHeroIsHiddenFromVoiceOver() throws {
    let hero = try captureHeroSource()

    XCTAssertTrue(hero.contains(".accessibilityHidden(true)"))
  }

  /// The capture stage's hero block, from the stage's declaration to the next stage
  /// section, so the assertions stay scoped to the illustration rather than the file.
  private func captureHeroSource() throws -> String {
    let source = try String(
      contentsOf: iosRoot().appendingPathComponent(
        "Feature/Estimate/ReverseScanMealView.swift"),
      encoding: .utf8
    )

    guard
      let start = source.range(of: "private var captureStageView"),
      let end = source.range(
        of: "// MARK: - Stage 2: Analyzing", range: start.upperBound..<source.endIndex)
    else {
      XCTFail("Could not locate the capture stage in ReverseScanMealView.swift")
      return source
    }

    return String(source[start.lowerBound..<end.lowerBound])
  }

  private func iosRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
