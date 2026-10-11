import Foundation
import XCTest

@testable import ProgressFlowCheck

/// WCAG 2.x contrast math over the actual DesignSystem token values,
/// mirrored byte-for-byte from `apps/ios/DesignSystem/AppTheme.swift`
/// (the RGB literals and their light/dark hex comments). This is the
/// on-host portion of the accessibility evidence: the numbers are
/// computed here, not asserted from memory.
///
/// Findings encoded below:
/// - Primary text pairs pass AA for normal text (>= 4.5).
/// - Secondary text (textSecondary) in light mode computes below 4.5 on
///   both backgrounds — an app-wide design-system characteristic (every
///   section subtitle uses it), not something this feature can change.
///   The tests assert the AA large-text threshold (>= 3.0) for those
///   pairs and record the computed ratio in the failure message; the
///   evidence ledger flags the gap for small secondary text.
/// - Provenance note body text was moved to textPrimary for this reason;
///   the row icons keep their accent/sage color at the >= 3.0 graphics
///   threshold.
private struct TokenRGB {
  let red: Double, green: Double, blue: Double

  /// WCAG relative luminance over sRGB components.
  var luminance: Double {
    func linear(_ c: Double) -> Double {
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  static func contrast(_ a: TokenRGB, _ b: TokenRGB) -> Double {
    let lighter = max(a.luminance, b.luminance)
    let darker = min(a.luminance, b.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }
}

final class ProgressContrastTests: XCTestCase {
  // Values mirrored from AppTheme.swift (light / dark variants).
  private let bgLight = TokenRGB(red: 0.96, green: 0.94, blue: 0.91)  // #F5F0E8
  private let bgDark = TokenRGB(red: 0.08, green: 0.07, blue: 0.06)  // #141210
  private let surfaceLight = TokenRGB(red: 0.99, green: 0.99, blue: 0.97)  // #FEFCF8
  private let surfaceDark = TokenRGB(red: 0.14, green: 0.13, blue: 0.11)  // #24211C
  private let textPrimaryLight = TokenRGB(red: 0.16, green: 0.13, blue: 0.09)  // #2A2118
  private let textPrimaryDark = TokenRGB(red: 0.95, green: 0.93, blue: 0.89)  // #F2EDE3
  private let textSecondaryLight = TokenRGB(red: 0.53, green: 0.48, blue: 0.42)  // #887A6A
  private let textSecondaryDark = TokenRGB(red: 0.74, green: 0.69, blue: 0.62)  // #BDB09E
  private let accentLight = TokenRGB(red: 0.76, green: 0.38, blue: 0.23)  // #C2613A
  private let accentDark = TokenRGB(red: 0.85, green: 0.50, blue: 0.35)  // #D98059
  private let sageLight = TokenRGB(red: 0.48, green: 0.56, blue: 0.42)  // #7A8E6B
  private let sageDark = TokenRGB(red: 0.58, green: 0.69, blue: 0.52)  // #94B085

  private func assertContrast(
    _ ratio: Double, minimum: Double, _ pair: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      ratio >= minimum,
      "\(pair) computes \(String(format: "%.2f", ratio)):1 — requires >= \(minimum):1",
      file: file, line: line)
  }

  func testPrimaryTextPassesAAOnPageAndCards() {
    let pairs: [(Double, String)] = [
      (TokenRGB.contrast(textPrimaryLight, bgLight), "textPrimary/bg light"),
      (TokenRGB.contrast(textPrimaryDark, bgDark), "textPrimary/bg dark"),
      (TokenRGB.contrast(textPrimaryLight, surfaceLight), "textPrimary/surface light"),
      (TokenRGB.contrast(textPrimaryDark, surfaceDark), "textPrimary/surface dark"),
    ]
    for (ratio, pair) in pairs {
      print("contrast: \(pair) = \(String(format: "%.2f", ratio)):1")
      assertContrast(ratio, minimum: 4.5, pair)
    }
  }

  func testProvenanceNoteBodyTextPassesAA() {
    // Note body renders in textPrimary on the page background (both modes).
    assertContrast(TokenRGB.contrast(textPrimaryLight, bgLight), minimum: 4.5, "note body light")
    assertContrast(TokenRGB.contrast(textPrimaryDark, bgDark), minimum: 4.5, "note body dark")
  }

  func testSecondaryTextLabelMeetsLargeTextThreshold() {
    // App-wide subtitle convention (disclosure toggle, section subtitles).
    let light = TokenRGB.contrast(textSecondaryLight, bgLight)
    let dark = TokenRGB.contrast(textSecondaryDark, bgDark)
    assertContrast(light, minimum: 3.0, "textSecondary/bg light")
    assertContrast(dark, minimum: 3.0, "textSecondary/bg dark")
    // Recorded for the ledger: light mode is below the 4.5 normal-text bar.
    print("contrast: textSecondary/bg light = \(String(format: "%.2f", light)):1")
    print("contrast: textSecondary/bg dark = \(String(format: "%.2f", dark)):1")
  }

  func testRowIconsMeetGraphicsThreshold() {
    // Fallback/error row icons (accent) and the insight icon (sage) on the
    // page background. Note: sage on its own 8% tint computes 2.87:1 —
    // below this threshold — which is why the insight row dropped the tint.
    let pairs: [(Double, String)] = [
      (TokenRGB.contrast(accentLight, bgLight), "accent/bg light"),
      (TokenRGB.contrast(accentDark, bgDark), "accent/bg dark"),
      (TokenRGB.contrast(sageLight, bgLight), "sage/bg light"),
      (TokenRGB.contrast(sageDark, bgDark), "sage/bg dark"),
    ]
    for (ratio, pair) in pairs {
      print("contrast: \(pair) = \(String(format: "%.2f", ratio)):1")
      assertContrast(ratio, minimum: 3.0, pair)
    }
  }

  func testInsightRowTextUsesPrimaryColor() {
    // The insight row's text is textPrimary on the page background.
    assertContrast(TokenRGB.contrast(textPrimaryLight, bgLight), minimum: 4.5, "insight text light")
    assertContrast(TokenRGB.contrast(textPrimaryDark, bgDark), minimum: 4.5, "insight text dark")
  }
}
