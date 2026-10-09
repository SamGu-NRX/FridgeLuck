import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import FridgeLuck

/// Behavioral tests for the theme tokens and View extensions in
/// apps/ios/DesignSystem/AppTheme.swift (DS01 slice).
///
/// Colors are resolved through UIColor with explicit light/dark trait
/// collections so each test can assert on both appearances of a dynamic token.
final class DS01ThemeTests: XCTestCase {
  private typealias Components = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)

  // MARK: - Resolution helpers

  private func resolved(_ color: Color, style: UIUserInterfaceStyle) -> Components {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    UIColor(color)
      .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      .getRed(&r, green: &g, blue: &b, alpha: &a)
    return (r, g, b, a)
  }

  /// WCAG relative luminance of a resolved color (alpha ignored).
  private func luminance(_ c: Components) -> CGFloat {
    func linear(_ v: CGFloat) -> CGFloat {
      if v <= 0.03928 { return v / 12.92 }
      return CGFloat(pow((Double(v) + 0.055) / 1.055, 2.4))
    }
    return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
  }

  private func contrastRatio(_ first: Components, _ second: Components) -> CGFloat {
    let lighter = max(luminance(first), luminance(second))
    let darker = min(luminance(first), luminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func assertSameComponents(
    _ lhs: Color,
    _ rhs: Color,
    style: UIUserInterfaceStyle,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let appearance = style == .dark ? "dark" : "light"
    let a = resolved(lhs, style: style)
    let b = resolved(rhs, style: style)
    XCTAssertEqual(a.r, b.r, accuracy: 0.0005, "\(message) — red (\(appearance))", file: file, line: line)
    XCTAssertEqual(a.g, b.g, accuracy: 0.0005, "\(message) — green (\(appearance))", file: file, line: line)
    XCTAssertEqual(a.b, b.b, accuracy: 0.0005, "\(message) — blue (\(appearance))", file: file, line: line)
    XCTAssertEqual(a.a, b.a, accuracy: 0.0005, "\(message) — alpha (\(appearance))", file: file, line: line)
  }

  private func assertDynamic(
    _ color: Color,
    name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let light = resolved(color, style: .light)
    let dark = resolved(color, style: .dark)
    let tolerance: CGFloat = 0.005
    let adapts =
      abs(light.r - dark.r) > tolerance
      || abs(light.g - dark.g) > tolerance
      || abs(light.b - dark.b) > tolerance
      || abs(light.a - dark.a) > tolerance
    XCTAssertTrue(adapts, "\(name) must adapt between light and dark mode", file: file, line: line)
  }

  // MARK: - Spacing scale

  func testNamedSpacingScaleIsStrictlyIncreasing() {
    XCTAssertLessThan(AppTheme.Space.xxxs, AppTheme.Space.xxs)
    XCTAssertLessThan(AppTheme.Space.xxs, AppTheme.Space.xs)
    XCTAssertLessThan(AppTheme.Space.xs, AppTheme.Space.sm)
    XCTAssertLessThan(AppTheme.Space.sm, AppTheme.Space.md)
    XCTAssertLessThan(AppTheme.Space.md, AppTheme.Space.lg)
    XCTAssertLessThan(AppTheme.Space.lg, AppTheme.Space.xl)
    XCTAssertLessThan(AppTheme.Space.xl, AppTheme.Space.xxl)
  }

  func testAllSpacingConstantsArePositive() {
    let constants: [(name: String, value: CGFloat)] = [
      ("xxxs", AppTheme.Space.xxxs),
      ("xxs", AppTheme.Space.xxs),
      ("xs", AppTheme.Space.xs),
      ("sm", AppTheme.Space.sm),
      ("md", AppTheme.Space.md),
      ("lg", AppTheme.Space.lg),
      ("xl", AppTheme.Space.xl),
      ("xxl", AppTheme.Space.xxl),
      ("page", AppTheme.Space.page),
      ("sectionBreak", AppTheme.Space.sectionBreak),
      ("bottomClearance", AppTheme.Space.bottomClearance),
      ("buttonVertical", AppTheme.Space.buttonVertical),
      ("chipVertical", AppTheme.Space.chipVertical),
      ("cardImageHeight", AppTheme.Space.cardImageHeight),
      ("ringHeroSize", AppTheme.Space.ringHeroSize),
      ("ringCompactSize", AppTheme.Space.ringCompactSize),
      ("ringMacroSize", AppTheme.Space.ringMacroSize),
    ]
    for constant in constants {
      XCTAssertGreaterThan(constant.value, 0, "Space.\(constant.name) must be positive")
    }
  }

  func testSectionBreakAndBottomClearanceScaleAboveTheSpacingSteps() {
    XCTAssertGreaterThan(AppTheme.Space.sectionBreak, AppTheme.Space.xl)
    XCTAssertLessThan(AppTheme.Space.sectionBreak, AppTheme.Space.xxl)
    XCTAssertGreaterThan(AppTheme.Space.bottomClearance, AppTheme.Space.sectionBreak)
  }

  func testRingSizesStayOrderedFromHeroToMacro() {
    XCTAssertGreaterThan(AppTheme.Space.ringHeroSize, AppTheme.Space.ringCompactSize)
    XCTAssertGreaterThan(AppTheme.Space.ringCompactSize, AppTheme.Space.ringMacroSize)
  }

  // MARK: - Radius scale

  func testRadiusScaleIsStrictlyIncreasingAndPositive() {
    XCTAssertGreaterThan(AppTheme.Radius.sm, 0)
    XCTAssertLessThan(AppTheme.Radius.sm, AppTheme.Radius.md)
    XCTAssertLessThan(AppTheme.Radius.md, AppTheme.Radius.lg)
    XCTAssertLessThan(AppTheme.Radius.lg, AppTheme.Radius.xl)
    XCTAssertLessThan(AppTheme.Radius.xl, AppTheme.Radius.xxl)
  }

  // MARK: - Color tokens

  func testBackgroundsGetDarkerAndTextGetsLighterInDarkMode() {
    // Guards against swapped dynamic(light:dark:) arguments — the most
    // plausible regression for these token declarations.
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.bg, style: .light)),
      luminance(resolved(AppTheme.bg, style: .dark))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.bgDeep, style: .light)),
      luminance(resolved(AppTheme.bgDeep, style: .dark))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.textPrimary, style: .dark)),
      luminance(resolved(AppTheme.textPrimary, style: .light))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.textSecondary, style: .dark)),
      luminance(resolved(AppTheme.textSecondary, style: .light))
    )
  }

  func testPrimaryTextMeetsAAContrastOnPageBackgroundInBothModes() {
    let light = contrastRatio(
      resolved(AppTheme.textPrimary, style: .light),
      resolved(AppTheme.bg, style: .light)
    )
    let dark = contrastRatio(
      resolved(AppTheme.textPrimary, style: .dark),
      resolved(AppTheme.bg, style: .dark)
    )
    XCTAssertGreaterThanOrEqual(light, 4.5)
    XCTAssertGreaterThanOrEqual(dark, 4.5)
  }

  func testSurfacesReadAbovePageBackgroundInBothModes() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      XCTAssertGreaterThan(
        luminance(resolved(AppTheme.surface, style: style)),
        luminance(resolved(AppTheme.bg, style: style)),
        "surface must read above the page background (\(style == .dark ? "dark" : "light"))"
      )
      XCTAssertGreaterThan(
        luminance(resolved(AppTheme.surfaceElevated, style: style)),
        luminance(resolved(AppTheme.bg, style: style)),
        "surfaceElevated must read above the page background (\(style == .dark ? "dark" : "light"))"
      )
    }
  }

  func testSurfaceElevatedIsLiftedAboveSurfaceInDarkMode() {
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.surfaceElevated, style: .dark)),
      luminance(resolved(AppTheme.surface, style: .dark))
    )
  }

  func testAccentLightIsLighterThanAccentInBothModes() {
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.accentLight, style: .light)),
      luminance(resolved(AppTheme.accent, style: .light))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.accentLight, style: .dark)),
      luminance(resolved(AppTheme.accent, style: .dark))
    )
  }

  func testSageLightIsLighterThanSageInBothModes() {
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.sageLight, style: .light)),
      luminance(resolved(AppTheme.sage, style: .light))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.sageLight, style: .dark)),
      luminance(resolved(AppTheme.sage, style: .dark)),
      "sageLight must stay lighter than sage in dark mode"
    )
  }

  func testChartBarGradientKeepsTopLighterThanBottomInBothModes() {
    // HomeAnalyticsSections and DashboardView draw bars with a
    // bottom -> top gradient of [chartBarBottom, chartBarTop]; a dark-mode
    // inversion flips the visual direction of every chart bar.
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.chartBarTop, style: .light)),
      luminance(resolved(AppTheme.chartBarBottom, style: .light))
    )
    XCTAssertGreaterThan(
      luminance(resolved(AppTheme.chartBarTop, style: .dark)),
      luminance(resolved(AppTheme.chartBarBottom, style: .dark))
    )
  }

  func testAccentMutedIsTranslucent() {
    let light = resolved(AppTheme.accentMuted, style: .light)
    let dark = resolved(AppTheme.accentMuted, style: .dark)
    XCTAssertGreaterThan(light.a, 0, "accentMuted must stay translucent in light mode")
    XCTAssertLessThan(light.a, 1, "accentMuted must stay translucent in light mode")
    XCTAssertGreaterThan(dark.a, 0, "accentMuted must stay translucent in dark mode")
    XCTAssertLessThan(dark.a, 1, "accentMuted must stay translucent in dark mode")
  }

  func testShadowDeepIsStrongerThanNormalAndBothStrengthenInDarkMode() {
    let normalLight = resolved(AppTheme.Shadow.color, style: .light).a
    let normalDark = resolved(AppTheme.Shadow.color, style: .dark).a
    let deepLight = resolved(AppTheme.Shadow.colorDeep, style: .light).a
    let deepDark = resolved(AppTheme.Shadow.colorDeep, style: .dark).a

    XCTAssertGreaterThan(deepLight, normalLight, "deep shadow must be stronger in light mode")
    XCTAssertGreaterThan(deepDark, normalDark, "deep shadow must be stronger in dark mode")
    XCTAssertGreaterThan(normalDark, normalLight, "shadow must strengthen in dark mode")
    XCTAssertGreaterThan(deepDark, deepLight, "deep shadow must strengthen in dark mode")
    for alpha in [normalLight, normalDark, deepLight, deepDark] {
      XCTAssertGreaterThan(alpha, 0)
      XCTAssertLessThan(alpha, 1)
    }
  }

  func testSlabStrokeStrengthensInDarkMode() {
    let light = resolved(AppTheme.slabStroke, style: .light).a
    let dark = resolved(AppTheme.slabStroke, style: .dark).a
    XCTAssertGreaterThan(light, 0)
    XCTAssertLessThan(light, 1)
    XCTAssertGreaterThan(dark, light, "slab stroke must strengthen in dark mode")
  }

  func testAliasTokensTrackTheirBaseTokensInBothModes() {
    let aliases: [(alias: Color, base: Color, name: String)] = [
      (AppTheme.positive, AppTheme.sage, "positive"),
      (AppTheme.warning, AppTheme.accent, "warning"),
      (AppTheme.neutral, AppTheme.textSecondary, "neutral"),
      (AppTheme.charcoal, AppTheme.deepOlive, "charcoal"),
      (AppTheme.slabFill, AppTheme.deepOlive, "slabFill"),
      (AppTheme.homePanel, AppTheme.deepOlive, "homePanel"),
      (AppTheme.homePanelStroke, AppTheme.slabStroke, "homePanelStroke"),
      (AppTheme.chartLine, AppTheme.accent, "chartLine"),
      (AppTheme.chartProtein, AppTheme.sage, "chartProtein"),
      (AppTheme.chartCarbs, AppTheme.oat, "chartCarbs"),
      (AppTheme.chartFat, AppTheme.accentLight, "chartFat"),
      (AppTheme.macroProtein, AppTheme.sage, "macroProtein"),
      (AppTheme.macroCarbs, AppTheme.oat, "macroCarbs"),
      (AppTheme.macroFat, AppTheme.accentLight, "macroFat"),
      (AppTheme.macroCalorie, AppTheme.accent, "macroCalorie"),
    ]
    for alias in aliases {
      assertSameComponents(
        alias.alias, alias.base, style: .light,
        "\(alias.name) must track its base token"
      )
      assertSameComponents(
        alias.alias, alias.base, style: .dark,
        "\(alias.name) must track its base token"
      )
    }
  }

  func testCoreColorTokensAdaptBetweenLightAndDarkMode() {
    let tokens: [(color: Color, name: String)] = [
      (AppTheme.bg, "bg"),
      (AppTheme.bgDeep, "bgDeep"),
      (AppTheme.surface, "surface"),
      (AppTheme.surfaceMuted, "surfaceMuted"),
      (AppTheme.textPrimary, "textPrimary"),
      (AppTheme.textSecondary, "textSecondary"),
      (AppTheme.accent, "accent"),
      (AppTheme.accentLight, "accentLight"),
      (AppTheme.accentMuted, "accentMuted"),
      (AppTheme.sage, "sage"),
      (AppTheme.sageLight, "sageLight"),
      (AppTheme.oat, "oat"),
      (AppTheme.dustyRose, "dustyRose"),
      (AppTheme.deepOlive, "deepOlive"),
      (AppTheme.deepOliveLight, "deepOliveLight"),
      (AppTheme.heroLight, "heroLight"),
      (AppTheme.heroMid, "heroMid"),
      (AppTheme.Shadow.color, "Shadow.color"),
      (AppTheme.Shadow.colorDeep, "Shadow.colorDeep"),
      (AppTheme.slabStroke, "slabStroke"),
    ]
    for token in tokens {
      assertDynamic(token.color, name: token.name)
    }
  }

  // MARK: - Typography

  func testTypographyTokensAreDistinctWithinTheirFamilies() {
    XCTAssertNotEqual(AppTheme.Typography.displayLarge, AppTheme.Typography.displayMedium)
    XCTAssertNotEqual(AppTheme.Typography.displayMedium, AppTheme.Typography.displaySmall)
    XCTAssertNotEqual(AppTheme.Typography.displaySmall, AppTheme.Typography.displayCaption)
    XCTAssertNotEqual(AppTheme.Typography.bodyLarge, AppTheme.Typography.bodyMedium)
    XCTAssertNotEqual(AppTheme.Typography.bodyMedium, AppTheme.Typography.bodySmall)
    XCTAssertNotEqual(AppTheme.Typography.dataLarge, AppTheme.Typography.dataMedium)
    XCTAssertNotEqual(AppTheme.Typography.dataMedium, AppTheme.Typography.dataSmall)
    XCTAssertNotEqual(AppTheme.Typography.label, AppTheme.Typography.labelSmall)
    XCTAssertNotEqual(AppTheme.Typography.settingsCaption, AppTheme.Typography.settingsCaptionMedium)
    XCTAssertNotEqual(AppTheme.Typography.settingsBody, AppTheme.Typography.settingsDetail)
    XCTAssertNotEqual(AppTheme.Typography.settingsBody, AppTheme.Typography.settingsBodySemibold)
    XCTAssertNotEqual(AppTheme.Typography.dataHero, AppTheme.Typography.displayLarge)
  }

  // MARK: - View modifiers

  @MainActor
  func testFlPagePaddingAddsPageSpacingToBothHorizontalEdges() {
    let base = fittedSize(Text("FridgeLuck"))
    let padded = fittedSize(Text("FridgeLuck").flPagePadding())

    XCTAssertEqual(padded.width - base.width, 2 * AppTheme.Space.page, accuracy: 1.0)
    XCTAssertEqual(padded.height, base.height, accuracy: 1.0)
  }

  @MainActor
  func testFlPageBackgroundLiveRenderModeRendersWithoutCrashing() {
    let controller = UIHostingController(rootView: Color.clear.flPageBackground())
    controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    controller.loadViewIfNeeded()
    controller.view.layoutIfNeeded()

    XCTAssertEqual(controller.view.bounds.width, 320, accuracy: 1.0)
  }

  @MainActor
  func testFlPageBackgroundInteractiveRenderModeRendersWithoutCrashing() {
    let controller = UIHostingController(
      rootView: Color.clear.flPageBackground(renderMode: .interactive)
    )
    controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    controller.loadViewIfNeeded()
    controller.view.layoutIfNeeded()

    XCTAssertEqual(controller.view.bounds.width, 320, accuracy: 1.0)
  }

  @MainActor
  private func fittedSize(_ view: some View) -> CGSize {
    let controller = UIHostingController(rootView: view)
    return controller.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
  }
}
