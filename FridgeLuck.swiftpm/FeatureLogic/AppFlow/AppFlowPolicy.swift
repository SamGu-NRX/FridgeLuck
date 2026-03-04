public enum ScanEntryRoute: Sendable, Equatable {
  case scan
  case onboarding
}

public enum DashboardEntryRoute: Sendable, Equatable {
  case dashboard
  case profile
  case onboarding
}

public enum AppFlowPolicy {
  public static func scanEntryRoute(hasOnboarded: Bool) -> ScanEntryRoute {
    hasOnboarded ? .scan : .onboarding
  }

  public static func dashboardEntryRoute(
    hasOnboarded: Bool,
    isTutorialComplete: Bool
  ) -> DashboardEntryRoute {
    guard hasOnboarded else { return .onboarding }
    return isTutorialComplete ? .dashboard : .profile
  }
}

// MARK: - Reset Policy

public enum ResetPolicy {
  public static func tutorialKeysToClear(
    allKeys: [String],
    preserving preservedKey: String
  ) -> [String] {
    allKeys.filter { $0 != preservedKey }
  }

  public static func defaultsKeysToClear(
    tutorialKeys: [String],
    learningKeys: [String]
  ) -> [String] {
    learningKeys + tutorialKeys
  }
}
