public struct DemoFallbackDecision: Sendable {
  public let usedBundledFixture: Bool
  public let usedStarterFallback: Bool

  public init(usedBundledFixture: Bool, usedStarterFallback: Bool) {
    self.usedBundledFixture = usedBundledFixture
    self.usedStarterFallback = usedStarterFallback
  }
}

public enum DemoFallbackPolicy {
  public static func shouldUseLiveVision(
    scenarioIsDefault: Bool,
    hasDemoImage: Bool,
    detectionCount: Int
  ) -> Bool {
    scenarioIsDefault && hasDemoImage && detectionCount > 0
  }

  public static func fallbackDecision(hasFixtureDetections: Bool) -> DemoFallbackDecision {
    if hasFixtureDetections {
      return DemoFallbackDecision(usedBundledFixture: true, usedStarterFallback: false)
    }
    return DemoFallbackDecision(usedBundledFixture: true, usedStarterFallback: true)
  }
}
