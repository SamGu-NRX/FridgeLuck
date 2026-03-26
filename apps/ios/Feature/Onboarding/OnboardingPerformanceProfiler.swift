import Foundation
import os

enum OnboardingPerformanceProfiler {
  private static let clock = ContinuousClock()
  private static let logger = Logger(
    subsystem: "samgu.FridgeLuck",
    category: "OnboardingPerformance"
  )

  static func begin(_ name: String) -> ContinuousClock.Instant {
    logger.log("\(name, privacy: .public) begin")
    return clock.now
  }

  static func end(_ name: String, from start: ContinuousClock.Instant) {
    let elapsed = clock.now - start
    logger.log(
      "\(name, privacy: .public) end \(elapsed.milliseconds, format: .fixed(precision: 2)) ms"
    )
  }
}

extension Duration {
  fileprivate var milliseconds: Double {
    (Double(components.seconds) * 1_000)
      + (Double(components.attoseconds) / 1_000_000_000_000_000)
  }
}
