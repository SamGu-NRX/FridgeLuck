import SwiftUI

enum AppMotion {
  static let standard: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)
  static let gentle: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.20)
  static let quick: Animation = .timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.14)
  static let press: Animation = .timingCurve(0.18, 0.9, 0.22, 1.0, duration: 0.12)
  static let onboardingStep: Animation = .timingCurve(0.18, 0.96, 0.24, 1.0, duration: 0.22)
  static let spotlightMove: Animation = .spring(response: 0.30, dampingFraction: 0.88)
  static let staggerDelay: Double = 0.035

  static let cardSpring: Animation = .spring(response: 0.35, dampingFraction: 0.72)
  static let buttonSpring: Animation = .spring(response: 0.28, dampingFraction: 0.68)
  static let heroAppear: Animation = .spring(response: 0.5, dampingFraction: 0.78)
  static let chartReveal: Animation = .spring(response: 0.6, dampingFraction: 0.82)

  static let pageTurn: Animation = .spring(response: 0.38, dampingFraction: 0.80)
  static let celebration: Animation = .spring(response: 0.55, dampingFraction: 0.70)
  static let starBounce: Animation = .spring(response: 0.24, dampingFraction: 0.55)
  static let counterReveal: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.6)
  static let sectionReveal: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
  static let confettiDuration: Double = 2.8

  // Scan-mode fan menu — independent X/Y springs
  /// Horizontal spread: fast, minimal overshoot — layout establishes quickly
  static let menuExpandX: Animation = .spring(response: 0.32, dampingFraction: 0.84)
  /// Vertical settle: slower, meaningful overshoot — rises above rest, drifts down
  static let menuSettleY: Animation = .spring(response: 0.48, dampingFraction: 0.72)
  /// Quick presence: fast ease-out for opacity + backdrop
  static let menuPresence: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.12)
  /// Bubble scale: medium spring, no bobble
  static let menuScale: Animation = .spring(response: 0.35, dampingFraction: 0.80)
  /// Label text: delayed reveal with upward slide
  static let menuLabel: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.14)
  /// Fast simultaneous collapse on dismiss
  static let menuDismiss: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.18)

  // Onboarding — step-by-step flow
  /// Ruler drag: responsive spring for continuous tracking
  static let rulerDrag: Animation = .spring(response: 0.18, dampingFraction: 0.92)
  /// Ruler snap: bouncy spring on release to nearest tick
  static let rulerSnap: Animation = .spring(response: 0.32, dampingFraction: 0.72)
  /// Selection card press scale
  static let selectionPress: Animation = .spring(response: 0.24, dampingFraction: 0.80)
  /// Chip toggle: quick pop
  static let chipToggle: Animation = .spring(response: 0.22, dampingFraction: 0.76)
  /// Chip reflow: use ease-in-out for neighboring pills shifting on-screen
  static let chipReflow: Animation = .timingCurve(0.645, 0.045, 0.355, 1.0, duration: 0.22)
  /// Progress bar width change
  static let progressBar: Animation = .spring(response: 0.40, dampingFraction: 0.84)

  // Color transitions — selection states, toggles, status changes
  /// 150ms ease (asymmetrical — faster start, smooth settle)
  static let colorTransition: Animation = .timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.15)

  // Onboarding — staggered entrance system
  /// Each element in a step entrance uses this spring
  static let staggerEntrance: Animation = .spring(response: 0.45, dampingFraction: 0.82)
  /// Delay between successive staggered elements (seconds)
  static let staggerInterval: Double = 0.06
  /// Setup bridge ring fill animation
  static let ringFill: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.2)
  /// Welcome hero choreography — slower, more dramatic entrance
  static let heroEntrance: Animation = .spring(response: 0.55, dampingFraction: 0.80)
  /// Welcome hero pill float-in
  static let heroPill: Animation = .spring(response: 0.50, dampingFraction: 0.75)
  /// Feature bridge auto-advance delay (seconds)
  static let bridgeAutoDuration: Double = 2.8
  /// Confetti burst on personalWelcome / handoff
  static let confettiBurst: Animation = .spring(response: 0.60, dampingFraction: 0.65)
  /// Crossfade for rotating setup messages
  static let messageCrossfade: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.35)

  // Live Assistant — camera-first cooking guide
  /// Panel snap to detent after drag ends
  static let panelSnap: Animation = .spring(response: 0.38, dampingFraction: 0.82)
  /// AI response bubble entrance
  static let bubbleAppear: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
  /// AI response bubble exit
  static let bubbleDismiss: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.30)
  /// Mic button active pulsing ring
  static let micPulse: Animation = .easeInOut(duration: 1.2)
  /// Camera resize when panel expands
  static let cameraResize: Animation = .spring(response: 0.40, dampingFraction: 0.84)
}
