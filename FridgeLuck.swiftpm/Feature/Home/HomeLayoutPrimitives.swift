import SwiftUI

// MARK: - Hero Card Button Style

struct FLHeroCardButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
      .animation(reduceMotion ? nil : AppMotion.cardSpring, value: configuration.isPressed)
  }
}
