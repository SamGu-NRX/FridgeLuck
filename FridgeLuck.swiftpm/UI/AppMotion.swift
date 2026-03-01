import SwiftUI

enum AppMotion {
  static let standard: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)
  static let gentle: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.20)
  static let quick: Animation = .timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.14)
  static let press: Animation = .timingCurve(0.18, 0.9, 0.22, 1.0, duration: 0.12)
  static let onboardingStep: Animation = .timingCurve(0.18, 0.96, 0.24, 1.0, duration: 0.22)
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
}
