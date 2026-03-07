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

  // Scan-mode popup menu — layered choreography
  /// Arc path: slightly underdamped spring for organic overshoot
  static let menuArc: Animation = .spring(response: 0.52, dampingFraction: 0.74)
  /// Bubble scale: tighter spring, no bobble
  static let menuScale: Animation = .spring(response: 0.42, dampingFraction: 0.82)
  /// Bubble opacity: fast ease-out to establish presence
  static let menuFade: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.16)
  /// Label text: delayed reveal with slide
  static let menuLabel: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.14)
  /// Fast collapse on dismiss — no stagger, all at once
  static let menuDismiss: Animation = .timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.20)
  /// Cascade delay between left and right options
  static let menuStagger: Double = 0.055
}
