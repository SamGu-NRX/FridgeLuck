import SwiftUI
import UIKit

// MARK: - Scan Mode

/// The two scan entry points accessible from the camera orb.
enum ScanMode: String, CaseIterable {
  case scanIngredients
  case logMeal

  var label: String {
    switch self {
    case .scanIngredients: return "Scan Ingredients"
    case .logMeal: return "Log a Meal"
    }
  }

  var icon: String {
    switch self {
    case .scanIngredients: return "camera.viewfinder"
    case .logMeal: return "camera.macro"
    }
  }
}

// MARK: - Scan Mode Menu

/// Horizontal fan popup that appears above the camera orb.
///
/// **Tap** the orb: popup fans out with two options.
/// **Long-press** the orb: popup appears with haptic, user can drag
/// to either side and release to select.
///
/// The two options fan out horizontally from the orb center like wings,
/// with a slight upward offset for visual lift.
struct ScanModeMenu: View {
  @Binding var isPresented: Bool
  @Binding var highlightedMode: ScanMode?
  let onSelect: (ScanMode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Staggered entrance control.
  @State private var optionsVisible = false

  // Layout constants
  private let fanRadius: CGFloat = 88
  private let optionSize: CGFloat = 72
  private let liftOffset: CGFloat = -14

  var body: some View {
    ZStack {
      // Backdrop
      Color.black.opacity(isPresented ? 0.18 : 0)
        .ignoresSafeArea()
        .onTapGesture {
          dismissMenu()
        }
        .animation(reduceMotion ? nil : AppMotion.menuDismiss, value: isPresented)
        .allowsHitTesting(isPresented)

      // Fan options positioned relative to screen bottom center
      GeometryReader { geo in
        let centerX = geo.size.width / 2
        let bottomY =
          geo.size.height - geo.safeAreaInsets.bottom
          - AppTheme.Home.orbSize / 2
          - AppTheme.Home.navOrbLift
          - AppTheme.Home.navBaseOffset
          + 6  // nudge to visually align with orb center

        // Left option: Scan Ingredients
        optionBubble(
          mode: .scanIngredients,
          isHighlighted: highlightedMode == .scanIngredients
        )
        .position(
          x: optionsVisible ? centerX - fanRadius : centerX,
          y: optionsVisible ? bottomY + liftOffset : bottomY
        )
        .scaleEffect(optionsVisible ? 1 : 0.6)
        .opacity(optionsVisible ? 1 : 0)
        .animation(
          reduceMotion ? nil : AppMotion.menuReveal,
          value: optionsVisible
        )

        // Right option: Log a Meal
        optionBubble(
          mode: .logMeal,
          isHighlighted: highlightedMode == .logMeal
        )
        .position(
          x: optionsVisible ? centerX + fanRadius : centerX,
          y: optionsVisible ? bottomY + liftOffset : bottomY
        )
        .scaleEffect(optionsVisible ? 1 : 0.6)
        .opacity(optionsVisible ? 1 : 0)
        .animation(
          reduceMotion
            ? nil : AppMotion.menuReveal.delay(AppMotion.menuStagger),
          value: optionsVisible
        )
      }
      .allowsHitTesting(isPresented)
    }
    .onChange(of: isPresented) { _, presented in
      if presented {
        if reduceMotion {
          optionsVisible = true
        } else {
          withAnimation(AppMotion.menuReveal) {
            optionsVisible = true
          }
        }
      } else {
        optionsVisible = false
        highlightedMode = nil
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityLabel("Scan mode menu")
  }

  // MARK: - Option Bubble

  private func optionBubble(
    mode: ScanMode,
    isHighlighted: Bool
  ) -> some View {
    Button {
      selectMode(mode)
    } label: {
      VStack(spacing: AppTheme.Space.xxs) {
        ZStack {
          Circle()
            .fill(isHighlighted ? AppTheme.accent : AppTheme.surface)
            .frame(width: optionSize, height: optionSize)
            .shadow(
              color: isHighlighted
                ? AppTheme.accent.opacity(0.35)
                : AppTheme.Shadow.colorDeep.opacity(0.25),
              radius: isHighlighted ? 16 : 10,
              x: 0,
              y: isHighlighted ? 6 : 4
            )
            .overlay(
              Circle()
                .stroke(
                  isHighlighted
                    ? AppTheme.accent.opacity(0.5)
                    : AppTheme.oat.opacity(0.30),
                  lineWidth: 1
                )
            )

          Image(systemName: mode.icon)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isHighlighted ? .white : AppTheme.accent)
        }

        Text(mode.label)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(
            isHighlighted ? AppTheme.accent : AppTheme.textPrimary
          )
          .lineLimit(1)
          .fixedSize()
      }
      .scaleEffect(isHighlighted ? 1.08 : 1.0)
      .animation(
        reduceMotion ? nil : AppMotion.buttonSpring,
        value: isHighlighted
      )
    }
    .buttonStyle(ScanModeOptionButtonStyle())
    .accessibilityLabel(mode.label)
    .accessibilityHint("Double tap to \(mode.label.lowercased())")
  }

  // MARK: - Actions

  private func selectMode(_ mode: ScanMode) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    dismissMenu()

    // Small delay so the dismiss animation plays before navigation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      onSelect(mode)
    }
  }

  private func dismissMenu() {
    if reduceMotion {
      isPresented = false
    } else {
      withAnimation(AppMotion.menuDismiss) {
        isPresented = false
      }
    }
  }
}

// MARK: - Option Button Style

private struct ScanModeOptionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
      .animation(
        reduceMotion ? nil : AppMotion.press,
        value: configuration.isPressed
      )
  }
}

// MARK: - Highlight Helper

/// Static helpers for updating highlight state from drag gestures.
enum ScanModeMenuGesture {

  /// Determine which mode (if any) is highlighted based on horizontal drag.
  static func highlightedMode(
    for translation: CGSize
  ) -> ScanMode? {
    let threshold: CGFloat = 30

    if translation.width < -threshold {
      return .scanIngredients
    } else if translation.width > threshold {
      return .logMeal
    }
    return nil
  }
}
