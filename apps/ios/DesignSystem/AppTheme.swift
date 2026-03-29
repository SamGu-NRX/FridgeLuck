import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - Design System

enum AppTheme {

  private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
  }

  private struct RGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
  }

  private static func dynamic(light: RGB, dark: RGB) -> Color {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let active = traits.userInterfaceStyle == .dark ? dark : light
          return UIColor(red: active.red, green: active.green, blue: active.blue, alpha: 1)
        }
      )
    #else
      Color(red: Double(light.red), green: Double(light.green), blue: Double(light.blue))
    #endif
  }

  private static func dynamic(light: RGBA, dark: RGBA) -> Color {
    #if canImport(UIKit)
      Color(
        uiColor: UIColor { traits in
          let active = traits.userInterfaceStyle == .dark ? dark : light
          return UIColor(
            red: active.red,
            green: active.green,
            blue: active.blue,
            alpha: active.alpha
          )
        }
      )
    #else
      Color(
        red: Double(light.red),
        green: Double(light.green),
        blue: Double(light.blue),
        opacity: Double(light.alpha)
      )
    #endif
  }

  // MARK: Backgrounds — warm linen, not sterile white

  static let bg = dynamic(
    light: RGB(red: 0.96, green: 0.94, blue: 0.91),  // #F5F0E8
    dark: RGB(red: 0.08, green: 0.07, blue: 0.06)  // #141210
  )
  static let bgDeep = dynamic(
    light: RGB(red: 0.91, green: 0.88, blue: 0.83),  // #E8E0D4
    dark: RGB(red: 0.10, green: 0.09, blue: 0.07)  // #1A1712
  )

  // MARK: Surfaces

  static let surface = dynamic(
    light: RGB(red: 0.99, green: 0.99, blue: 0.97),  // #FEFCF8
    dark: RGB(red: 0.14, green: 0.13, blue: 0.11)  // #24211C
  )
  static let surfaceMuted = dynamic(
    light: RGB(red: 0.94, green: 0.91, blue: 0.87),  // #F0E8DE
    dark: RGB(red: 0.18, green: 0.16, blue: 0.14)  // #2E2924
  )

  // MARK: Text — warm walnut, not cold black

  static let textPrimary = dynamic(
    light: RGB(red: 0.16, green: 0.13, blue: 0.09),  // #2A2118
    dark: RGB(red: 0.95, green: 0.93, blue: 0.89)  // #F2EDE3
  )
  static let textSecondary = dynamic(
    light: RGB(red: 0.53, green: 0.48, blue: 0.42),  // #887A6A
    dark: RGB(red: 0.74, green: 0.69, blue: 0.62)  // #BDB09E
  )

  // MARK: Primary accent — terracotta

  static let accent = dynamic(
    light: RGB(red: 0.76, green: 0.38, blue: 0.23),  // #C2613A
    dark: RGB(red: 0.85, green: 0.50, blue: 0.35)  // #D98059
  )
  static let accentLight = dynamic(
    light: RGB(red: 0.89, green: 0.62, blue: 0.48),  // #E39E7A
    dark: RGB(red: 0.92, green: 0.69, blue: 0.55)  // #EBB08C
  )
  static let accentMuted = accent.opacity(0.12)

  // MARK: Secondary accent — sage

  static let sage = dynamic(
    light: RGB(red: 0.48, green: 0.56, blue: 0.42),  // #7A8E6B
    dark: RGB(red: 0.58, green: 0.69, blue: 0.52)  // #94B085
  )
  static let sageLight = dynamic(
    light: RGB(red: 0.72, green: 0.78, blue: 0.68),  // #B8C7AD
    dark: RGB(red: 0.44, green: 0.54, blue: 0.41)  // #708A68
  )

  // MARK: Warm neutrals

  static let oat = dynamic(
    light: RGB(red: 0.83, green: 0.72, blue: 0.56),  // #D4B78F
    dark: RGB(red: 0.81, green: 0.71, blue: 0.55)  // #CFB58C
  )
  static let dustyRose = dynamic(
    light: RGB(red: 0.75, green: 0.62, blue: 0.59),  // #C09E96
    dark: RGB(red: 0.77, green: 0.64, blue: 0.61)  // #C4A39C
  )

  // MARK: Status — muted, warm variants

  static let positive = sage
  static let warning = accent
  static let neutral = textSecondary

  // MARK: Dark surfaces — warm charcoal, editorial depth

  static let deepOlive = dynamic(
    light: RGB(red: 0.12, green: 0.14, blue: 0.10),  // #1E2419
    dark: RGB(red: 0.12, green: 0.11, blue: 0.09)  // #1E1C17
  )
  static let deepOliveLight = dynamic(
    light: RGB(red: 0.18, green: 0.20, blue: 0.15),  // #2E3326
    dark: RGB(red: 0.17, green: 0.16, blue: 0.14)  // #2C2924
  )
  static let charcoal = deepOlive

  // MARK: Dark surface chrome

  static let slabFill = deepOlive
  static let slabStroke = dynamic(
    light: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.10),
    dark: RGBA(red: 1.0, green: 0.96, blue: 0.90, alpha: 0.12)
  )
  static let homePanel = deepOlive
  static let homePanelStroke = slabStroke

  // MARK: Hero gradient (warm amber, editorial)

  static let heroLight = dynamic(
    light: RGB(red: 0.94, green: 0.88, blue: 0.78),  // #F0E0C7
    dark: RGB(red: 0.38, green: 0.30, blue: 0.22)  // #614D38
  )
  static let heroMid = dynamic(
    light: RGB(red: 0.83, green: 0.72, blue: 0.56),  // #D4B78F
    dark: RGB(red: 0.52, green: 0.40, blue: 0.28)  // #856648
  )

  // MARK: Chart tokens

  static let chartLine = accent
  static let chartProtein = sage
  static let chartCarbs = oat
  static let chartFat = accentLight
  static let chartBarBottom = sage
  static let chartBarTop = sageLight

  // MARK: Macro visualization aliases
  static let macroProtein = sage
  static let macroCarbs = oat
  static let macroFat = accentLight
  static let macroCalorie = accent

  // MARK: Elevated surface (lifted in dark mode)
  static let surfaceElevated = dynamic(
    light: RGB(red: 0.99, green: 0.99, blue: 0.97),
    dark: RGB(red: 0.16, green: 0.14, blue: 0.12)
  )

  // MARK: - Spacing (editorial, intentional, consistent)

  enum Space {
    static let xxxs: CGFloat = 2  // micro: stat label gaps, thin separators
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    static let page: CGFloat = 24  // standard horizontal page margin
    static let sectionBreak: CGFloat = 40  // between major sections
    static let bottomClearance: CGFloat = 100  // bottom nav safe area
    static let buttonVertical: CGFloat = 18  // primary/secondary button padding
    static let chipVertical: CGFloat = 6  // pill/chip vertical padding
    static let cardImageHeight: CGFloat = 180
    static let ringHeroSize: CGFloat = 120
    static let ringCompactSize: CGFloat = 68
    static let ringMacroSize: CGFloat = 44
  }

  // MARK: - Radius

  enum Radius {
    static let sm: CGFloat = 12
    static let md: CGFloat = 18
    static let lg: CGFloat = 22
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 36
  }

  // MARK: - Depth (warm, layered shadows)

  enum Shadow {
    static let color = dynamic(
      light: RGBA(red: 0.20, green: 0.16, blue: 0.10, alpha: 0.08),
      dark: RGBA(red: 0.06, green: 0.04, blue: 0.02, alpha: 0.30)
    )
    static let colorDeep = dynamic(
      light: RGBA(red: 0.20, green: 0.16, blue: 0.10, alpha: 0.15),
      dark: RGBA(red: 0.06, green: 0.04, blue: 0.02, alpha: 0.50)
    )
    static let radius: CGFloat = 16
    static let y: CGFloat = 8
  }

  // MARK: - Home layout constants

  enum Home {
    static let orbSize: CGFloat = 76
    static let navOrbLift: CGFloat = 18
    static let navBaseOffset: CGFloat = 14
    static let navCenterGap: CGFloat = 78
    static let navHorizontalInset: CGFloat = 14
    static let navCornerRadius: CGFloat = 28
    static let navIconSize: CGFloat = 18
    static let statDividerHeight: CGFloat = 36
  }

  // MARK: - Typography

  enum Typography {
    static let displayLarge = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let displayMedium = Font.system(.title, design: .serif, weight: .bold)
    static let displaySmall = Font.system(.title2, design: .serif, weight: .semibold)
    static let displayCaption = Font.system(.title3, design: .serif, weight: .medium)

    static let bodyLarge = Font.system(.body, weight: .regular)
    static let bodyMedium = Font.system(.subheadline, weight: .regular)
    static let bodySmall = Font.system(.caption, weight: .medium)

    static let dataLarge = Font.system(.title, design: .rounded, weight: .bold)
    static let dataMedium = Font.system(.headline, design: .rounded, weight: .bold)
    static let dataSmall = Font.system(.subheadline, design: .rounded, weight: .semibold)
    static let label = Font.system(.caption, design: .rounded, weight: .semibold)
    static let labelSmall = Font.system(.caption2, design: .rounded, weight: .semibold)
    static let dataHero = Font.system(.largeTitle, design: .rounded, weight: .bold)

    // Settings — intentionally .default design for utility surfaces
    static let settingsTitle = Font.system(.title3, design: .default, weight: .semibold)
    static let settingsBody = Font.system(.body, design: .default, weight: .medium)
    static let settingsDetail = Font.system(.subheadline, design: .default, weight: .regular)
    static let settingsCaption = Font.system(.caption, design: .default, weight: .regular)
    static let settingsCaptionMedium = Font.system(.caption, design: .default, weight: .medium)
    static let settingsHeadline = Font.system(.headline, design: .default, weight: .semibold)
    static let settingsBodySemibold = Font.system(.body, design: .default, weight: .semibold)
  }
}

// MARK: - View modifiers

extension View {
  func flPageBackground(renderMode: FLAmbientBackgroundRenderMode = .live) -> some View {
    background(
      FLAmbientBackground(renderMode: renderMode)
        .ignoresSafeArea()
    )
  }

  /// Standard page horizontal padding.
  func flPagePadding() -> some View {
    padding(.horizontal, AppTheme.Space.page)
  }
}
