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

// MARK: - Fan Arc Geometry Effect

/// Translates a view along a quadratic Bezier arc as `progress` animates from 0 → 1.
///
/// At `progress = 0` the view is offset by `startOffset` (at the orb center).
/// At `progress = 1` the offset is (0, 0) — the view sits at its natural `.position()`.
/// The `controlOffset` shapes the arc curvature between start and end.
///
/// Because `progress` is the single `animatableData`, SwiftUI interpolates along the
/// true curved path on every frame — no straight-line cheating.
private struct FanArcEffect: GeometryEffect {
  var progress: CGFloat

  let startOffset: CGPoint
  let controlOffset: CGPoint

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    let t = progress
    let u = 1.0 - t

    // Quadratic Bezier: P(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
    // P0 = startOffset (orb center), P1 = controlOffset, P2 = (0, 0)
    let x = u * u * startOffset.x + 2.0 * u * t * controlOffset.x
    let y = u * u * startOffset.y + 2.0 * u * t * controlOffset.y

    return ProjectionTransform(CGAffineTransform(translationX: x, y: y))
  }
}

// MARK: - Scan Mode Menu

/// Horizontal fan popup that emerges from the camera orb.
///
/// Each option sweeps outward along a curved arc path with layered
/// timing: position (spring) → scale (tighter spring) → opacity (fast
/// ease-out) → label (delayed slide-up). The second option is staggered
/// by 55ms for a cascading wing-spread feel. Dismiss collapses everything
/// simultaneously for responsiveness.
struct ScanModeMenu: View {
  @Binding var isPresented: Bool
  @Binding var highlightedMode: ScanMode?
  let onSelect: (ScanMode) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - Animation State

  /// Per-option arc progress (staggered entrance)
  @State private var leftArcProgress: CGFloat = 0
  @State private var rightArcProgress: CGFloat = 0

  /// Shared visual layers
  @State private var bubbleScale: CGFloat = 0.86
  @State private var bubbleOpacity: Double = 0
  @State private var labelOpacity: Double = 0
  @State private var labelSlide: CGFloat = 6
  @State private var backdropOpacity: Double = 0

  // MARK: - Layout Constants

  /// Horizontal distance from orb center to each option's final position.
  private let fanSpread: CGFloat = 92
  /// Vertical lift above the orb center at rest.
  private let fanLift: CGFloat = 28
  /// Extra vertical lift at the arc's peak (controls how much the path curves upward).
  private let arcPeak: CGFloat = 22
  /// Diameter of each option circle.
  private let optionSize: CGFloat = 72

  // MARK: - Arc Parameters

  /// Bezier offsets for the LEFT option (Scan Ingredients).
  /// Start: at the orb center relative to the option's final position
  /// (right and down from final pos). Control: halfway back, lifted above.
  private var leftStartOffset: CGPoint {
    CGPoint(x: fanSpread, y: fanLift)
  }
  private var leftControlOffset: CGPoint {
    CGPoint(x: fanSpread * 0.52, y: -arcPeak)
  }

  /// Bezier offsets for the RIGHT option (Log a Meal) — mirror of left.
  private var rightStartOffset: CGPoint {
    CGPoint(x: -fanSpread, y: fanLift)
  }
  private var rightControlOffset: CGPoint {
    CGPoint(x: -fanSpread * 0.52, y: -arcPeak)
  }

  // MARK: - Body

  var body: some View {
    ZStack {
      // Dimmed backdrop
      Color.black.opacity(backdropOpacity)
        .ignoresSafeArea()
        .onTapGesture { dismissMenu() }
        .allowsHitTesting(isPresented)

      // Fan options positioned relative to screen bottom center
      GeometryReader { geo in
        let centerX = geo.size.width / 2
        let orbCenterY =
          geo.size.height - geo.safeAreaInsets.bottom
          - AppTheme.Home.orbSize / 2
          - AppTheme.Home.navOrbLift
          - AppTheme.Home.navBaseOffset
          + 6  // visual alignment nudge

        // Left option: Scan Ingredients
        optionBubble(
          mode: .scanIngredients,
          isHighlighted: highlightedMode == .scanIngredients
        )
        .modifier(
          FanArcEffect(
            progress: leftArcProgress,
            startOffset: leftStartOffset,
            controlOffset: leftControlOffset
          )
        )
        .position(x: centerX - fanSpread, y: orbCenterY - fanLift)

        // Right option: Log a Meal
        optionBubble(
          mode: .logMeal,
          isHighlighted: highlightedMode == .logMeal
        )
        .modifier(
          FanArcEffect(
            progress: rightArcProgress,
            startOffset: rightStartOffset,
            controlOffset: rightControlOffset
          )
        )
        .position(x: centerX + fanSpread, y: orbCenterY - fanLift)
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

  // MARK: - Option Bubble

  private func optionBubble(
    mode: ScanMode,
    isHighlighted: Bool
  ) -> some View {
    Button {
      selectMode(mode)
    } label: {
      VStack(spacing: AppTheme.Space.xxs) {
        // Icon circle
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

        // Label — independent fade + slide
        Text(mode.label)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(
            isHighlighted ? AppTheme.accent : AppTheme.textPrimary
          )
          .lineLimit(1)
          .fixedSize()
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

  /// Layered entrance: backdrop → opacity/scale → arc (staggered) → labels
  private func revealMenu() {
    // Layer 1: Backdrop dims
    withAnimation(AppMotion.menuFade) {
      backdropOpacity = 0.18
    }

    // Layer 2: Bubbles fade in + scale up (quick — establishes presence)
    withAnimation(AppMotion.menuFade) {
      bubbleOpacity = 1
    }
    withAnimation(AppMotion.menuScale) {
      bubbleScale = 1.0
    }

    // Layer 3: Arc paths (spring, staggered per option)
    withAnimation(AppMotion.menuArc) {
      leftArcProgress = 1
    }
    withAnimation(AppMotion.menuArc.delay(AppMotion.menuStagger)) {
      rightArcProgress = 1
    }

    // Layer 4: Labels slide up + fade in (delayed — after icons settle)
    withAnimation(AppMotion.menuLabel.delay(0.10)) {
      labelOpacity = 1
      labelSlide = 0
    }
  }

  /// Fast simultaneous collapse — no stagger on exit for responsiveness.
  private func collapseMenu() {
    withAnimation(AppMotion.menuDismiss) {
      leftArcProgress = 0
      rightArcProgress = 0
      bubbleScale = 0.86
      bubbleOpacity = 0
      labelOpacity = 0
      labelSlide = 6
      backdropOpacity = 0
    }
    highlightedMode = nil
  }

  /// Accessibility: instant state change, no animation.
  private func applyInstant(visible: Bool) {
    leftArcProgress = visible ? 1 : 0
    rightArcProgress = visible ? 1 : 0
    bubbleScale = visible ? 1 : 0.86
    bubbleOpacity = visible ? 1 : 0
    labelOpacity = visible ? 1 : 0
    labelSlide = visible ? 0 : 6
    backdropOpacity = visible ? 0.18 : 0
    if !visible { highlightedMode = nil }
  }

  // MARK: - Actions

  private func selectMode(_ mode: ScanMode) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    dismissMenu()

    // Small delay so the dismiss animation plays before navigation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
