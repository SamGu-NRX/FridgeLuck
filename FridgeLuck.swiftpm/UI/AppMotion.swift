import SwiftUI

enum AppMotion {
  // Fast, responsive defaults for product UI (under 300ms).
  static let standard: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.24)
  static let gentle: Animation = .timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.20)
  static let quick: Animation = .timingCurve(0.2, 0.8, 0.2, 1.0, duration: 0.14)
  static let press: Animation = .timingCurve(0.18, 0.9, 0.22, 1.0, duration: 0.12)
  static let onboardingStep: Animation = .timingCurve(0.18, 0.96, 0.24, 1.0, duration: 0.22)
  static let staggerDelay: Double = 0.035
}
