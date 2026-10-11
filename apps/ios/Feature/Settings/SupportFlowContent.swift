import SwiftUI

/// Contextual recovery topics shown in the Help flow.
///
/// The state -> action mapping is the app mirror of the canonical contract
/// pinned by `apps/ios/Tools/help-recovery-check` (HelpRecoveryCore).
/// Topic copy stays generic on purpose: it names what the user can do
/// next, never a service status we cannot observe.
struct SupportRecoveryTopic: Identifiable, Equatable {
  let id: String
  let title: String
  let summary: String
  let steps: [String]
  let actions: [SupportFlowAction]
}

struct SupportFlowAction: Identifiable, Equatable {
  enum Destination: Equatable {
    case openSettings
    case replayQuest(TutorialQuest)
    case replayOnboarding
    case diagnosticsPreview
  }

  let id: String
  let title: String
  let icon: String
  let destination: Destination
}

enum SupportRecoveryContent {
  static let topics: [SupportRecoveryTopic] = [
    SupportRecoveryTopic(
      id: "camera-denied",
      title: "Camera is not available",
      summary: "The scan screen needs camera access before it can capture anything.",
      steps: [
        "Open iOS Settings for FridgeLuck and allow the camera.",
        "Come back and start the scan again - nothing else on your phone is touched.",
      ],
      actions: [
        SupportFlowAction(
          id: "open-settings", title: "Open Permission Settings",
          icon: "gear", destination: .openSettings),
        SupportFlowAction(
          id: "replay-first-scan", title: "Try the guided demo scan",
          icon: "camera.viewfinder", destination: .replayQuest(.firstScan)),
      ]),
    SupportRecoveryTopic(
      id: "library-denied",
      title: "Photo library is not available",
      summary: "Picking an existing photo needs library access.",
      steps: [
        "Allow photo access in Settings, or",
        "Use the camera instead of a saved photo for the next scan.",
      ],
      actions: [
        SupportFlowAction(
          id: "open-settings", title: "Open Permission Settings",
          icon: "gear", destination: .openSettings),
      ]),
    SupportRecoveryTopic(
      id: "partial-scan",
      title: "A scan stopped partway",
      summary:
        "The run saved what it saw so far, but some captures did not finish. Your history is intact.",
      steps: [
        "Retake the scan with the food in even light, filling the frame.",
        "Or add the item by hand from the fridge list.",
        "Nothing was deleted - the earlier attempt stays in your history.",
      ],
      actions: [
        SupportFlowAction(
          id: "replay-first-scan", title: "Practice with the guided demo scan",
          icon: "camera.viewfinder", destination: .replayQuest(.firstScan)),
        SupportFlowAction(
          id: "diagnostics", title: "Preview a diagnostic summary",
          icon: "stethoscope", destination: .diagnosticsPreview),
      ]),
    SupportRecoveryTopic(
      id: "empty-recognition",
      title: "Nothing was recognized",
      summary:
        "The scan finished but could not match any ingredients with enough confidence.",
      steps: [
        "Move closer and avoid glare or heavy shadows.",
        "Frame one or two items at a time.",
        "Or add the item by hand from the fridge list.",
      ],
      actions: [
        SupportFlowAction(
          id: "replay-first-scan", title: "See how a good scan looks",
          icon: "camera.viewfinder", destination: .replayQuest(.firstScan)),
        SupportFlowAction(
          id: "diagnostics", title: "Preview a diagnostic summary",
          icon: "stethoscope", destination: .diagnosticsPreview),
      ]),
    SupportRecoveryTopic(
      id: "cloud-unavailable",
      title: "Cloud assistance is unavailable",
      summary:
        "Optional cloud features can be down without affecting local scans, history, or recipes.",
      steps: [
        "Keep going locally - scans and your history work without it.",
        "Try the cloud feature again later.",
      ],
      actions: [
        SupportFlowAction(
          id: "diagnostics", title: "Preview a diagnostic summary",
          icon: "stethoscope", destination: .diagnosticsPreview),
      ]),
    SupportRecoveryTopic(
      id: "save-failed",
      title: "A scan could not be saved",
      summary:
        "The run finished but writing it to your history failed. The failure report is kept.",
      steps: [
        "Check free storage if this keeps happening.",
        "Preview the diagnostic summary below - it stays on your device until you share it.",
        "Retry the scan when ready. Nothing was partially written to your history.",
      ],
      actions: [
        SupportFlowAction(
          id: "diagnostics", title: "Preview a diagnostic summary",
          icon: "stethoscope", destination: .diagnosticsPreview),
      ]),
    SupportRecoveryTopic(
      id: "health-auth",
      title: "Apple Health is not fully connected",
      summary: "Health features stay off until authorization is granted in iOS.",
      steps: [
        "Open iOS Settings, then Privacy & Security, then Health.",
        "Allow FridgeLuck the categories you want.",
        "Return to the app and re-check the integration - nothing is written until you allow it.",
      ],
      actions: [
        SupportFlowAction(
          id: "open-settings", title: "Open Permission Settings",
          icon: "gear", destination: .openSettings),
      ]),
    SupportRecoveryTopic(
      id: "notification-auth",
      title: "Reminders are silent",
      summary:
        "Reminders need notification authorization; without it, scheduling quietly does nothing.",
      steps: [
        "Allow notifications in Settings for FridgeLuck.",
        "Come back and re-check your reminder rules - they were never deleted.",
      ],
      actions: [
        SupportFlowAction(
          id: "open-settings", title: "Open Permission Settings",
          icon: "gear", destination: .openSettings),
      ]),
  ]
}

/// Minimal entry added to SettingsHelpView. The pre-existing replay
/// controls around it are untouched.
struct SupportFlowHelpEntrySection: View {
  @Binding var showSupportFlow: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text("Something not working?")
        .font(.system(.body, design: .serif, weight: .semibold))
        .foregroundStyle(AppTheme.textPrimary)

      Text(
        "Fix a stuck scan, a missing permission, or a failed save - without replaying the whole tour."
      )
      .font(AppTheme.Typography.settingsDetail)
      .foregroundStyle(AppTheme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button(action: { showSupportFlow = true }) {
        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .accessibilityHidden(true)
          Text("Fix a problem")
            .font(AppTheme.Typography.settingsCaptionMedium)
        }
        .foregroundStyle(AppTheme.accent)
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.xs)
        .background(Capsule().fill(AppTheme.accent.opacity(0.10)))
      }
      .accessibilityHint("Opens step-by-step recovery for scan, save, and permission problems")
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(AppTheme.accent.opacity(0.04))
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(AppTheme.accent)
        .frame(width: 3)
        .padding(.vertical, AppTheme.Space.sm)
        .padding(.leading, 1)
    }
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.accent.opacity(0.15), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }
}
