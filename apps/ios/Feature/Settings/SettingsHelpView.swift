import SwiftUI

struct SettingsHelpView: View {
  @Environment(FirstRunExperienceStore.self) private var firstRunExperienceStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(TutorialStorageKeys.progress) private var tutorialStorageString = ""

  let onReplayQuest: (TutorialQuest) -> Void
  let onReplayOnboarding: () -> Void

  private var tutorialProgress: TutorialProgress {
    TutorialProgress(storageString: tutorialStorageString)
  }

  @State private var appeared = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
        Text("Learn the app step by step")
          .font(.system(.subheadline, design: .serif, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary)
          .padding(.horizontal, AppTheme.Space.page)

        VStack(spacing: AppTheme.Space.sm) {
          ForEach(TutorialQuest.allCases) { quest in
            questCard(quest)
          }
        }
        .padding(.horizontal, AppTheme.Space.page)

        Button(action: onReplayOnboarding) {
          HStack(spacing: AppTheme.Space.xs) {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: 14, weight: .semibold))
            Text("Replay full onboarding")
              .font(AppTheme.Typography.settingsBodySemibold)
          }
          .foregroundStyle(AppTheme.accent)
          .frame(maxWidth: .infinity)
          .padding(.vertical, AppTheme.Space.sm)
          .background(
            Capsule()
              .stroke(AppTheme.accent, lineWidth: 1.5)
          )
        }
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.top, AppTheme.Space.xs)

        if firstRunExperienceStore.hasCompletedCurrentVersion {
          FLSettingsFootnote(
            text: "You've completed onboarding. Replay it anytime to revisit setup guidance."
          )
          .padding(.horizontal, AppTheme.Space.page)
        }
      }
      .padding(.vertical, AppTheme.Space.md)
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .scrollContentBackground(.hidden)
    .flSettingsBottomClearance()
    .navigationTitle("Help")
    .navigationBarTitleDisplayMode(.large)
    .flPageBackground(renderMode: .interactive)
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance) { appeared = true }
      }
    }
  }

  private func questCard(_ quest: TutorialQuest) -> some View {
    let isComplete = tutorialProgress.isCompleted(quest)

    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .top) {
        Image(systemName: quest.icon)
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(quest.accentColor)

        Spacer()

        if isComplete {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(AppTheme.sage)
        } else {
          Text("Step \(quest.rawValue + 1)")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.xxxs)
            .background(
              Capsule().fill(AppTheme.surfaceMuted)
            )
        }
      }

      Text(quest.title)
        .font(.system(.body, design: .serif, weight: .semibold))
        .foregroundStyle(AppTheme.textPrimary)

      Text(quest.subtitle)
        .font(AppTheme.Typography.settingsDetail)
        .foregroundStyle(AppTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Button(action: { onReplayQuest(quest) }) {
        HStack(spacing: AppTheme.Space.xxs) {
          Image(systemName: quest.ctaIcon)
            .font(.system(size: 12, weight: .semibold))
          Text(isComplete ? "Revisit" : quest.ctaTitle)
            .font(AppTheme.Typography.settingsCaptionMedium)
        }
        .foregroundStyle(quest.accentColor)
        .padding(.horizontal, AppTheme.Space.sm)
        .padding(.vertical, AppTheme.Space.xs)
        .background(
          Capsule().fill(quest.accentColor.opacity(0.10))
        )
      }
    }
    .padding(AppTheme.Space.md)
    .background(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .fill(quest.accentColor.opacity(0.04))
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(quest.accentColor)
        .frame(width: 3)
        .padding(.vertical, AppTheme.Space.sm)
        .padding(.leading, 1)
    }
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(quest.accentColor.opacity(0.15), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(quest.title). \(quest.subtitle). \(isComplete ? "Complete" : "Not started")"
    )
  }
}
