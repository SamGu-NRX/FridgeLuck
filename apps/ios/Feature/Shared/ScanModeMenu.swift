import SwiftUI
import UIKit

// MARK: - Scan Mode

enum ScanMode: String, CaseIterable {
  case scanIngredients
  case updateGroceries
  case logMeal

  var label: String {
    switch self {
    case .scanIngredients: return "Scan Ingredients"
    case .updateGroceries: return "Update Groceries"
    case .logMeal: return "Log a Meal"
    }
  }

  var icon: String {
    switch self {
    case .scanIngredients: return "camera.viewfinder"
    case .updateGroceries: return "cart.fill"
    case .logMeal: return "fork.knife"
    }
  }
}

// MARK: - Fan Layout

private struct FanLayout {
  let radius: CGFloat = 112
  let sideAngle: CGFloat = 58

  private var sideAngleRad: CGFloat { sideAngle * .pi / 180 }

  var centerOffset: CGSize {
    CGSize(width: 0, height: -radius)
  }

  var leftOffset: CGSize {
    CGSize(
      width: -radius * sin(sideAngleRad),
      height: -radius * cos(sideAngleRad)
    )
  }

  var rightOffset: CGSize {
    CGSize(
      width: radius * sin(sideAngleRad),
      height: -radius * cos(sideAngleRad)
    )
  }
}

// MARK: - Scan Mode Menu

struct ScanModeMenu: View {
  @Binding var isPresented: Bool
  @Binding var highlightedMode: ScanMode?
  let onSelect: (ScanMode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - Animation State

  @State private var fanX: CGFloat = 0
  @State private var fanY: CGFloat = 0
  @State private var bubbleOpacity: Double = 0
  @State private var bubbleScale: CGFloat = 0.93
  @State private var labelOpacity: Double = 0
  @State private var labelSlide: CGFloat = 6
  @State private var backdropOpacity: Double = 0

  // MARK: - Layout

  private let layout = FanLayout()
  private let optionSize: CGFloat = 64
  private let backdropTargetOpacity: Double = 0.68
  private let labelBackgroundOpacity: Double = 0.54

  // MARK: - Body

  var body: some View {
    ZStack {
      Color.black.opacity(backdropOpacity)
        .ignoresSafeArea()
        .onTapGesture { dismissMenu() }
        .allowsHitTesting(isPresented)

      GeometryReader { geo in
        let centerX = geo.size.width / 2
        let orbCenterY =
          geo.size.height - geo.safeAreaInsets.bottom
          - AppTheme.Home.orbSize / 2
          - AppTheme.Home.navOrbLift
          - AppTheme.Home.navBaseOffset
          + 6

        optionBubble(
          mode: .scanIngredients,
          isHighlighted: highlightedMode == .scanIngredients
        )
        .offset(fanOffset(for: layout.leftOffset))
        .position(
          x: centerX + layout.leftOffset.width,
          y: orbCenterY + layout.leftOffset.height
        )

        optionBubble(
          mode: .updateGroceries,
          isHighlighted: highlightedMode == .updateGroceries
        )
        .offset(fanOffset(for: layout.centerOffset))
        .position(
          x: centerX + layout.centerOffset.width,
          y: orbCenterY + layout.centerOffset.height
        )

        optionBubble(
          mode: .logMeal,
          isHighlighted: highlightedMode == .logMeal
        )
        .offset(fanOffset(for: layout.rightOffset))
        .position(
          x: centerX + layout.rightOffset.width,
          y: orbCenterY + layout.rightOffset.height
        )
      }
      .allowsHitTesting(isPresented)
    }
    .onChange(of: isPresented) { _, presented in
      if reduceMotion {
        applyInstant(visible: presented)
      } else if presented {
        revealMenu()
      } else {
        collapseMenu()
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityLabel("Scan mode menu")
  }

  // MARK: - Fan Offset

  private func fanOffset(for finalOffset: CGSize) -> CGSize {
    CGSize(
      width: -finalOffset.width * (1 - fanX),
      height: -finalOffset.height * (1 - fanY)
    )
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
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isHighlighted ? .white : AppTheme.accent)
            .animation(reduceMotion ? nil : AppMotion.colorTransition, value: isHighlighted)
        }

        Text(mode.label)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.surface)
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, AppTheme.Space.xs)
          .padding(.vertical, 6)
          .background(
            Capsule(style: .continuous)
              .fill(Color.black.opacity(labelBackgroundOpacity))
          )
          .overlay(
            Capsule(style: .continuous)
              .stroke(.white.opacity(isHighlighted ? 0.22 : 0.12), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
          .opacity(labelOpacity)
          .offset(y: labelSlide)
      }
      .scaleEffect(isHighlighted ? 1.1 : 1.0)
      .animation(
        reduceMotion ? nil : AppMotion.buttonSpring,
        value: isHighlighted
      )
    }
    .buttonStyle(ScanModeOptionButtonStyle())
    .scaleEffect(bubbleScale)
    .opacity(bubbleOpacity)
    .accessibilityLabel(mode.label)
    .accessibilityHint("Double tap to \(mode.label.lowercased())")
  }

  // MARK: - Animation Choreography

  private func revealMenu() {
    withAnimation(.easeOut(duration: 0.22)) {
      backdropOpacity = backdropTargetOpacity
    }

    withAnimation(AppMotion.menuPresence) {
      bubbleOpacity = 1
    }

    withAnimation(AppMotion.menuScale) {
      bubbleScale = 1.0
    }

    withAnimation(AppMotion.menuExpandX) {
      fanX = 1
    }

    withAnimation(AppMotion.menuSettleY) {
      fanY = 1
    }

    withAnimation(AppMotion.menuLabel.delay(0.08)) {
      labelOpacity = 1
      labelSlide = 0
    }
  }

  private func collapseMenu() {
    withAnimation(AppMotion.menuDismiss) {
      fanX = 0
      fanY = 0
      bubbleOpacity = 0
      bubbleScale = 0.93
      labelOpacity = 0
      labelSlide = 6
      backdropOpacity = 0
    }
    highlightedMode = nil
  }

  private func applyInstant(visible: Bool) {
    fanX = visible ? 1 : 0
    fanY = visible ? 1 : 0
    bubbleOpacity = visible ? 1 : 0
    bubbleScale = visible ? 1 : 0.93
    labelOpacity = visible ? 1 : 0
    labelSlide = visible ? 0 : 6
    backdropOpacity = visible ? backdropTargetOpacity : 0
    if !visible { highlightedMode = nil }
  }

  // MARK: - Actions

  private func selectMode(_ mode: ScanMode) {
    AppPreferencesStore.haptic(.light)

    dismissMenu()

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      onSelect(mode)
    }
  }

  private func dismissMenu() {
    isPresented = false
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

enum ScanModeMenuGesture {
  static func highlightedMode(
    for translation: CGSize
  ) -> ScanMode? {
    let horizontalThreshold: CGFloat = 30
    let verticalThreshold: CGFloat = 20

    if translation.width < -horizontalThreshold {
      return .scanIngredients
    } else if translation.width > horizontalThreshold {
      return .logMeal
    }

    if translation.height < -verticalThreshold
      && abs(translation.width) < horizontalThreshold
    {
      return .updateGroceries
    }

    return nil
  }
}
