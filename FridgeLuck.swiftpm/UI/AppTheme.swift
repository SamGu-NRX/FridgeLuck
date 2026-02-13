import SwiftUI

enum AppTheme {
  static let accent = Color.yellow
  static let bg = Color(red: 0.98, green: 0.97, blue: 0.94)
  static let surface = Color.white
  static let surfaceMuted = Color(red: 0.95, green: 0.93, blue: 0.89)
  static let textPrimary = Color(red: 0.11, green: 0.10, blue: 0.08)
  static let textSecondary = Color(red: 0.37, green: 0.33, blue: 0.28)
  static let positive = Color.green
  static let warning = Color.orange
  static let neutral = Color.gray

  enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
  }

  enum Radius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
  }

  enum Shadow {
    static let color = Color.black.opacity(0.08)
    static let radius: CGFloat = 16
    static let y: CGFloat = 8
  }
}

extension View {
  func flPageBackground() -> some View {
    background(
      LinearGradient(
        colors: [AppTheme.bg, AppTheme.surfaceMuted.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    )
  }
}
