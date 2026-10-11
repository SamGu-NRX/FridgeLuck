import Foundation

/// Canonical, host-agnostic recovery contract for FridgeLuck's help flow.
///
/// Grounding in the fix/scan-failure-report sources:
/// - Permission gates surface through `AppPermissionStatus`
///   (apps/ios/Feature/Shared/AppPermissionCenter.swift), e.g. `.notDetermined`.
/// - Failed scans persist as `ScanOutcome.failed` plus
///   `ScanDiagnostics.requestFailures`
///   (apps/ios/Capability/Core/Recognition/ScanContracts.swift).
/// - Scan history is `ScanRunRecord`
///   (apps/ios/Capability/Core/Services/ScanRunStore.swift).
/// - Replay destinations come from `HelpTutorialReplayRoute`
///   (apps/ios/Feature/Settings/HelpTutorialReplayRoute.swift).
///
/// The module is deliberately pure Swift so `swift test` pins the
/// state -> action contract on any host, with no UIKit dependency.
public enum SupportRecoveryIssue: String, Codable, Sendable, CaseIterable {
  case cameraAccessDenied
  case photoLibraryAccessDenied
  case partialScan
  case emptyRecognition
  case cloudUnavailable
  case localSaveFailed
  case healthAuthorizationIncomplete
  case notificationAuthorizationIncomplete
}

public struct SupportRecoveryAction: Codable, Sendable, Equatable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case openPermissionSettings
    case retryScan
    case chooseDifferentInput
    case manualEntry
    case retryCloudRequest
    case retryLocalSave
    case replayQuest
    case replayOnboarding
    case openDiagnosticsPreview
  }

  public let kind: Kind
  /// Set only for `.replayQuest`; names the existing replay destination
  /// (a `TutorialQuest` routed through `HelpTutorialReplayRoute`).
  public let questTitle: String?

  public init(kind: Kind, questTitle: String? = nil) {
    self.kind = kind
    self.questTitle = questTitle
  }

  public var id: String {
    questTitle.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
  }

  /// Actions that only make sense when the host actually wires a handler.
  /// Hosts hide unwired actions instead of showing a dead control.
  public var requiresHostWiring: Bool {
    switch kind {
    case .retryScan, .chooseDifferentInput, .manualEntry,
      .retryCloudRequest, .retryLocalSave:
      return true
    case .openPermissionSettings, .replayQuest, .replayOnboarding,
      .openDiagnosticsPreview:
      return false
    }
  }
}

public struct SupportRecoveryPlan: Codable, Sendable, Equatable {
  public let issue: SupportRecoveryIssue
  public let actions: [SupportRecoveryAction]
}

/// Which host handlers currently exist. A missing flag means the
/// corresponding action is filtered out of the plan, never shown disabled.
public struct SupportHostWiring: Codable, Sendable, Equatable {
  public var canRetryScan: Bool
  public var canChooseInput: Bool
  public var canManualEntry: Bool
  public var canRetryCloud: Bool
  public var canRetryLocalSave: Bool

  public init(
    canRetryScan: Bool = false, canChooseInput: Bool = false,
    canManualEntry: Bool = false, canRetryCloud: Bool = false,
    canRetryLocalSave: Bool = false
  ) {
    self.canRetryScan = canRetryScan
    self.canChooseInput = canChooseInput
    self.canManualEntry = canManualEntry
    self.canRetryCloud = canRetryCloud
    self.canRetryLocalSave = canRetryLocalSave
  }
}

public enum SupportRecoveryMapping {
  /// Maps a stuck state to ordered recovery actions.
  ///
  /// Invariants (pinned by tests):
  /// - Returned actions all have real destinations: the system settings
  ///   URL, existing replay routes, wired host closures, or the local
  ///   diagnostics preview.
  /// - No action resets profile, history, or tutorial progress; recovery
  ///   is never "replay the whole tour" by default.
  public static func plan(
    for issue: SupportRecoveryIssue,
    wiring: SupportHostWiring
  ) -> SupportRecoveryPlan {
    let kinds: [(SupportRecoveryAction.Kind, Bool)] = {
      switch issue {
      case .cameraAccessDenied:
        // Denied camera access cannot be fixed in-app; the only real fix is
        // the system permission screen, then a retry once granted.
        return [(.openPermissionSettings, true), (.retryScan, wiring.canRetryScan)]
      case .photoLibraryAccessDenied:
        // Library denial: fix permission, or fall back to the other input.
        return [
          (.openPermissionSettings, true), (.chooseDifferentInput, wiring.canChooseInput),
        ]
      case .partialScan:
        // A partial scan still saved its diagnostics; recovering means
        // re-running the capture or entering data by hand. Replay of the
        // tutorial is never forced here.
        return [(.retryScan, wiring.canRetryScan), (.manualEntry, wiring.canManualEntry)]
      case .emptyRecognition:
        // Nothing recognized: guide toward better capture conditions and
        // manual entry; do not claim the content was bad.
        return [(.retryScan, wiring.canRetryScan), (.manualEntry, wiring.canManualEntry)]
      case .cloudUnavailable:
        // Cloud agent is optional; local-first flows keep working. Never
        // blocks the user on a service that may be down.
        return [(.retryCloudRequest, wiring.canRetryCloud), (.manualEntry, wiring.canManualEntry)]
      case .localSaveFailed:
        // A failed local save keeps the failure report; retry the save and
        // surface the user-triggered diagnostics preview.
        return [
          (.retryLocalSave, wiring.canRetryLocalSave), (.openDiagnosticsPreview, true),
        ]
      case .healthAuthorizationIncomplete:
        // Health authorization mirrors notification authorization: grant in
        // the system settings surface, then re-check in the app.
        return [(.openPermissionSettings, true)]
      case .notificationAuthorizationIncomplete:
        // Reminder scheduling without authorization degrades to in-app only;
        // the real fix is the system settings surface, not data changes.
        return [(.openPermissionSettings, true)]
      }
    }()

    let actions = kinds
      .filter { $0.1 }
      .map { kind -> SupportRecoveryAction in
        if kind == .replayQuest {
          return SupportRecoveryAction(kind: kind, questTitle: "Your First Scan")
        }
        return SupportRecoveryAction(kind: kind)
      }
    return SupportRecoveryPlan(issue: issue, actions: actions)
  }
}
