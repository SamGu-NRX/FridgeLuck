public enum ScanEntryRoute: Sendable, Equatable {
  case scan
  case onboarding
}

public enum SettingsEntryRoute: Sendable, Equatable {
  case settings
}

public enum KitchenEntryRoute: Sendable, Equatable {
  case kitchen
  case emptyState
}

public enum ProgressEntryRoute: Sendable, Equatable {
  case progress
  case emptyState
}

public enum AppFlowPolicy {
  public static func scanEntryRoute(hasOnboarded: Bool) -> ScanEntryRoute {
    hasOnboarded ? .scan : .onboarding
  }

  public static func settingsEntryRoute() -> SettingsEntryRoute {
    .settings
  }

  public static func kitchenEntryRoute(hasOnboarded: Bool) -> KitchenEntryRoute {
    hasOnboarded ? .kitchen : .emptyState
  }

  /// Progress opens for anyone who finished setup. It no longer waits on the guided tour,
  /// which real cooking never advanced.
  public static func progressEntryRoute(hasOnboarded: Bool) -> ProgressEntryRoute {
    hasOnboarded ? .progress : .emptyState
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
