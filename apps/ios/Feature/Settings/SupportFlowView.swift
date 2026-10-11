import SwiftUI
import UIKit

/// Sheet-hosted recovery flow. Presented from SettingsHelpView so the
/// excluded settings routing stays untouched. Existing replay callbacks
/// are passed straight through - replay behavior is preserved, and no
/// action here resets profile or history.
struct SupportFlowView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openURL) private var openURL

  // Existing public callbacks, preserved as-is.
  let onReplayQuest: (TutorialQuest) -> Void
  let onReplayOnboarding: () -> Void

  @State private var expandedTopicID: String?
  @State private var showDiagnostics = false
  @State private var appeared = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          Text(
            "Pick the problem you are seeing. Each fix uses what already exists in the app - nothing here erases your profile or history."
          )
          .font(AppTheme.Typography.settingsDetail)
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)
          .padding(.top, AppTheme.Space.xs)

          ForEach(SupportRecoveryContent.topics) { topic in
            topicCard(topic)
              .padding(.horizontal, AppTheme.Space.page)
          }

          secondaryReplayCard
            .padding(.horizontal, AppTheme.Space.page)
        }
        .padding(.bottom, AppTheme.Space.lg)
      }
      .scrollContentBackground(.hidden)
      .background(AppTheme.surfaceElevated)
      .navigationTitle("Fix a problem")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .opacity(appeared ? 1 : 0)
      .onAppear {
        guard !appeared else { return }
        if reduceMotion {
          appeared = true
        } else {
          withAnimation(AppMotion.standard) { appeared = true }
        }
      }
      .navigationDestination(isPresented: $showDiagnostics) {
        SupportDiagnosticsView()
      }
    }
  }

  private func topicCard(_ topic: SupportRecoveryTopic) -> some View {
    let isExpanded = expandedTopicID == topic.id

    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Button(action: {
        guard !reduceMotion else {
          expandedTopicID = isExpanded ? nil : topic.id
          return
        }
        withAnimation(AppMotion.standard) {
          expandedTopicID = isExpanded ? nil : topic.id
        }
      }) {
        HStack(alignment: .top, spacing: AppTheme.Space.sm) {
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(topic.title)
              .font(.system(.body, design: .serif, weight: .semibold))
              .foregroundStyle(AppTheme.textPrimary)
              .multilineTextAlignment(.leading)
            Text(topic.summary)
              .font(AppTheme.Typography.settingsDetail)
              .foregroundStyle(AppTheme.textSecondary)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: 0)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded ? "Collapses steps" : "Expands recovery steps")

      if isExpanded {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .top, spacing: AppTheme.Space.xs) {
              Text("\(index + 1).")
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.accent)
              Text(step)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
          }

          Divider()

          ForEach(topic.actions) { action in
            actionRow(action)
          }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(AppTheme.surfaceElevated.opacity(0.96))
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.22), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  private func actionRow(_ action: SupportFlowAction) -> some View {
    Button(action: { perform(action) }) {
      HStack(spacing: AppTheme.Space.xs) {
        Image(systemName: action.icon)
          .font(.system(size: 12, weight: .semibold))
          .accessibilityHidden(true)
        Text(action.title)
          .font(AppTheme.Typography.settingsCaptionMedium)
          .foregroundStyle(AppTheme.accent)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.xs)
      .background(Capsule().fill(AppTheme.accent.opacity(0.10)))
    }
    .buttonStyle(.plain)
    .accessibilityHint(accessibilityHint(for: action))
  }

  private func accessibilityHint(for action: SupportFlowAction) -> String {
    switch action.destination {
    case .openSettings:
      return "Opens iOS Settings for FridgeLuck, then returns here"
    case .replayQuest:
      return "Starts the guided demo scan you already know"
    case .replayOnboarding:
      return "Replays onboarding; your data is not changed"
    case .diagnosticsPreview:
      return "Shows a summary with no personal content, on this device only"
    }
  }

  private func perform(_ action: SupportFlowAction) {
    switch action.destination {
    case .openSettings:
      if let url = URL(string: UIApplication.openSettingsURLString) {
        openURL(url)
      }
    case .replayQuest(let quest):
      dismiss()
      onReplayQuest(quest)
    case .replayOnboarding:
      dismiss()
      onReplayOnboarding()
    case .diagnosticsPreview:
      showDiagnostics = true
    }
  }

  /// Explicitly secondary: replaying is offered as a choice, never forced
  /// as the fix, and reuses the existing callbacks unchanged.
  private var secondaryReplayCard: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text("Prefer to walk the guided tour again?")
        .font(.system(.body, design: .serif, weight: .semibold))
        .foregroundStyle(AppTheme.textPrimary)
      Text(
        "Replaying onboarding or a quest never erases your history - it only re-runs the walkthrough."
      )
      .font(AppTheme.Typography.settingsDetail)
      .foregroundStyle(AppTheme.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button(action: {
        dismiss()
        onReplayOnboarding()
      }) {
        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 12, weight: .semibold))
            .accessibilityHidden(true)
          Text("Replay full onboarding")
            .font(AppTheme.Typography.settingsCaptionMedium)
        }
        .foregroundStyle(AppTheme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Space.sm)
        .background(Capsule().stroke(AppTheme.accent, lineWidth: 1.5))
      }
      .buttonStyle(.plain)
      .padding(.top, AppTheme.Space.xxxs)
      .accessibilityHint("Replays onboarding; your data is not changed")
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(AppTheme.oat.opacity(0.06))
    )
    .accessibilityElement(children: .contain)
  }
}
