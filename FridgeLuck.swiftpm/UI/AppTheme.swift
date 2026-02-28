import SwiftUI

// MARK: - Design System

enum AppTheme {

  // MARK: Backgrounds — warm linen, not sterile white

  static let bg = Color(red: 0.96, green: 0.94, blue: 0.91)  // #F5F0E8  linen
  static let bgDeep = Color(red: 0.91, green: 0.88, blue: 0.83)  // #E8E0D4  linen deep

  // MARK: Surfaces

  static let surface = Color(red: 0.99, green: 0.99, blue: 0.97)  // #FEFCF8  warm white
  static let surfaceMuted = Color(red: 0.94, green: 0.91, blue: 0.87)  // #F0E8DE  muted warm

  // MARK: Text — warm walnut, not cold black

  static let textPrimary = Color(red: 0.16, green: 0.13, blue: 0.09)  // #2A2118  walnut
  static let textSecondary = Color(red: 0.53, green: 0.48, blue: 0.42)  // #887A6A  stone

  // MARK: Primary accent — terracotta

  static let accent = Color(red: 0.76, green: 0.38, blue: 0.23)  // #C2613A
  static let accentLight = Color(red: 0.89, green: 0.62, blue: 0.48)  // #E39E7A
  static let accentMuted = Color(red: 0.76, green: 0.38, blue: 0.23).opacity(0.12)

  // MARK: Secondary accent — sage

  static let sage = Color(red: 0.48, green: 0.56, blue: 0.42)  // #7A8E6B
  static let sageLight = Color(red: 0.72, green: 0.78, blue: 0.68)  // #B8C7AD

  // MARK: Warm neutrals

  static let oat = Color(red: 0.83, green: 0.72, blue: 0.56)  // #D4B78F
  static let dustyRose = Color(red: 0.75, green: 0.62, blue: 0.59)  // #C09E96

  // MARK: Status — muted, warm variants

  static let positive = Color(red: 0.48, green: 0.56, blue: 0.42)  // sage
  static let warning = Color(red: 0.76, green: 0.38, blue: 0.23)  // terracotta
  static let neutral = Color(red: 0.53, green: 0.48, blue: 0.42)  // stone

  // MARK: Dark surfaces — deep olive, not cold charcoal

  static let deepOlive = Color(red: 0.12, green: 0.14, blue: 0.10)  // #1E2419
  static let deepOliveLight = Color(red: 0.18, green: 0.20, blue: 0.15)  // #2E3326
  static let charcoal = Color(red: 0.12, green: 0.14, blue: 0.10)  // alias

  // MARK: Dark surface chrome

  static let slabFill = Color(red: 0.12, green: 0.14, blue: 0.10)
  static let slabStroke = Color.white.opacity(0.09)
  static let homePanel = Color(red: 0.12, green: 0.14, blue: 0.10)
  static let homePanelStroke = Color.white.opacity(0.10)

  // MARK: Hero gradient (warm amber, editorial)

  static let heroLight = Color(red: 0.94, green: 0.88, blue: 0.78)  // #F0E0C7
  static let heroMid = Color(red: 0.83, green: 0.72, blue: 0.56)  // oat

  // MARK: Chart tokens

  static let chartLine = Color(red: 0.76, green: 0.38, blue: 0.23)  // terracotta
  static let chartProtein = Color(red: 0.48, green: 0.56, blue: 0.42)  // sage
  static let chartCarbs = Color(red: 0.83, green: 0.72, blue: 0.56)  // oat
  static let chartFat = Color(red: 0.89, green: 0.62, blue: 0.48)  // terracotta light
  static let chartBarBottom = Color(red: 0.48, green: 0.56, blue: 0.42)  // sage
  static let chartBarTop = Color(red: 0.72, green: 0.78, blue: 0.68)  // sage light

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

    // Named semantic tokens
    static let page: CGFloat = 24  // standard horizontal page margin
    static let sectionBreak: CGFloat = 40  // between major sections
    static let bottomClearance: CGFloat = 100  // bottom nav safe area
    static let buttonVertical: CGFloat = 18  // primary/secondary button padding
    static let chipVertical: CGFloat = 6  // pill/chip vertical padding
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
    static let color = Color(red: 0.20, green: 0.16, blue: 0.10).opacity(0.08)
    static let colorDeep = Color(red: 0.20, green: 0.16, blue: 0.10).opacity(0.15)
    static let radius: CGFloat = 16
    static let y: CGFloat = 8
  }

  // MARK: - Home layout constants

  enum Home {
    static let orbSize: CGFloat = 76
    static let navOrbLift: CGFloat = 18
    static let navBaseOffset: CGFloat = 14
    static let navCenterGap: CGFloat = 92
    static let navHorizontalInset: CGFloat = 14
    static let navCornerRadius: CGFloat = 28
    static let statDividerHeight: CGFloat = 36
  }

  // MARK: - Typography

  enum Typography {
    // Display — New York serif, the editorial voice
    static let displayLarge = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let displayMedium = Font.system(.title, design: .serif, weight: .bold)
    static let displaySmall = Font.system(.title2, design: .serif, weight: .semibold)
    static let displayCaption = Font.system(.title3, design: .serif, weight: .medium)

    // Body — SF Pro for readability
    static let bodyLarge = Font.system(.body, weight: .regular)
    static let bodyMedium = Font.system(.subheadline, weight: .regular)
    static let bodySmall = Font.system(.caption, weight: .medium)

    // UI — SF Pro Rounded for friendly data/labels
    static let dataLarge = Font.system(.title, design: .rounded, weight: .bold)
    static let dataMedium = Font.system(.headline, design: .rounded, weight: .bold)
    static let dataSmall = Font.system(.subheadline, design: .rounded, weight: .semibold)
    static let label = Font.system(.caption, design: .rounded, weight: .semibold)
    static let labelSmall = Font.system(.caption2, design: .rounded, weight: .semibold)
  }
}

// MARK: - View modifiers

extension View {
  func flPageBackground() -> some View {
    background(
      FLAmbientBackground()
        .ignoresSafeArea()
    )
  }

  /// Standard page horizontal padding.
  func flPagePadding() -> some View {
    padding(.horizontal, AppTheme.Space.page)
  }
}
