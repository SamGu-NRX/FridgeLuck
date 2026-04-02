import Foundation

enum OnboardingSetupBridgeTiming {
  static let leadIn: UInt64 = 80_000_000
  static let progressDuration: UInt64 = 2_200_000_000
  static let completionHold: UInt64 = 700_000_000
  static let totalVisualDuration: UInt64 = leadIn + progressDuration + completionHold
  static let reducedMotionDuration: UInt64 = 500_000_000
  static let progressSteps = 100
  static let progressStepDuration: UInt64 = progressDuration / UInt64(progressSteps)
}
