import SwiftUI

struct HomeTutorialWelcomeHeader: View {
  let heroAppeared: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      Text("Welcome to")
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.textSecondary)
        .textCase(.uppercase)
        .kerning(1.2)

      Text("FridgeLuck")
        .font(AppTheme.Typography.displayLarge)
        .foregroundStyle(AppTheme.textPrimary)

      Text(
        "Welcome to your guided tour. The steps unlock in order so the demo scan, review, recipe match, and live cook flow each land cleanly."
      )
      .font(AppTheme.Typography.bodyLarge)
      .foregroundStyle(AppTheme.textSecondary)
      .padding(.top, AppTheme.Space.xxs)
    }
    .opacity(heroAppeared ? 1 : 0)
    .offset(y: heroAppeared ? 0 : 16)
  }
}

struct HomeTutorialQuestSection: View {
  let tutorialProgress: TutorialProgress
  let tutorialStorageString: String
  let heroAppeared: Bool
  let reduceMotion: Bool
  let onQuestAction: (TutorialQuest) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      if let currentQuest = tutorialProgress.currentQuest {
        TutorialQuestCard(quest: currentQuest, state: .active) {
          onQuestAction(currentQuest)
        }
        .id("quest_\(currentQuest.rawValue)")
        .spotlightAnchor("quest_\(currentQuest.rawValue)")
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 12)
        .animation(
          reduceMotion
            ? nil
            : AppMotion.cardSpring.delay(
              Double(currentQuest.staggerIndex) * AppMotion.staggerDelay + 0.1),
          value: heroAppeared
        )
        .animation(reduceMotion ? nil : AppMotion.standard, value: tutorialStorageString)
      }
    }
  }
}

struct HomeTutorialQuickStartHint: View {
  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(AppTheme.oat)

      Text(
        "Start with \u{201C}Your First Scan\u{201D} \u{2014} demo mode gives you a safe first run."
      )
      .font(AppTheme.Typography.bodySmall)
      .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.oat.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.18), lineWidth: 1)
    )
  }
}
