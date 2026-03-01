import SwiftUI

// MARK: - Tutorial Quest Card

/// A quest card that adapts its appearance based on quest state:
/// - **active**: full card with icon, text, CTA button, accent gradient
/// - **locked**: dimmed, no CTA, "upcoming" feel
/// - **completed**: compact pill with checkmark
struct TutorialQuestCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let quest: TutorialQuest
  let state: QuestCardState
  let action: () -> Void

  enum QuestCardState: Sendable {
    case active
    case locked
    case completed
  }

  var body: some View {
    switch state {
    case .active:
      activeCard
    case .locked:
      lockedCard
    case .completed:
      completedPill
    }
  }

  // MARK: - Active Card

  private var activeCard: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .top, spacing: AppTheme.Space.sm) {
        Image(systemName: quest.icon)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 48, height: 48)
          .background(Circle().fill(.white.opacity(0.15)))

        VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
          Text(quest.title)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(.white)

          Text(quest.subtitle)
            .font(AppTheme.Typography.bodyMedium)
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(3)
        }
      }

      Button(action: action) {
        HStack(spacing: AppTheme.Space.xs) {
          Text(quest.ctaTitle)
            .font(AppTheme.Typography.label)
          Image(systemName: quest.ctaIcon)
            .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(quest.accentColor)
        .padding(.horizontal, AppTheme.Space.lg)
        .padding(.vertical, AppTheme.Space.buttonVertical)
        .frame(maxWidth: .infinity)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
      }
      .buttonStyle(.plain)
    }
    .padding(AppTheme.Space.lg)
    .background(
      LinearGradient(
        colors: [quest.accentColor, quest.accentColor.opacity(0.82)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
    )
    .overlay(alignment: .topTrailing) {
      Circle()
        .fill(.white.opacity(0.06))
        .frame(width: 120, height: 120)
        .blur(radius: 30)
        .offset(x: 30, y: -20)
        .allowsHitTesting(false)
    }
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
    .shadow(color: quest.accentColor.opacity(0.20), radius: 16, x: 0, y: 8)
  }

  // MARK: - Locked Card

  private var lockedCard: some View {
    HStack(spacing: AppTheme.Space.sm) {
      Image(systemName: "lock.fill")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
        .frame(width: 32, height: 32)
        .background(Circle().fill(AppTheme.surfaceMuted))

      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(quest.title)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.6))

        Text("Complete previous quest to unlock")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary.opacity(0.4))
      }

      Spacer()
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surfaceMuted.opacity(0.5),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.15), lineWidth: 1)
    )
  }

  // MARK: - Completed Pill

  private var completedPill: some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(quest.accentColor)

      Text(quest.title)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textPrimary)

      Spacer()

      Image(systemName: quest.icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(quest.accentColor.opacity(0.6))
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, AppTheme.Space.sm)
    .background(
      quest.accentColor.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
        .stroke(quest.accentColor.opacity(0.18), lineWidth: 1)
    )
  }
}
