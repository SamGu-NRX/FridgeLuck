import SwiftUI

// MARK: - Tutorial Progress View

/// Compact progress header showing arc indicator + completed quest pills.
/// Sits at the top of the tutorial home page.
struct TutorialProgressView: View {
  let progress: TutorialProgress

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .center, spacing: AppTheme.Space.md) {
        // Arc indicator
        ZStack {
          Circle()
            .stroke(AppTheme.oat.opacity(0.25), lineWidth: 5)
            .frame(width: 52, height: 52)

          Circle()
            .trim(from: 0, to: progress.progressFraction)
            .stroke(
              AppTheme.accent,
              style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )
            .frame(width: 52, height: 52)
            .rotationEffect(.degrees(-90))

          Text("\(progress.completedCount)/\(progress.totalCount)")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textPrimary)
        }

        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text(progressTitle)
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)

          Text(progressSubtitle)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Spacer()
      }

      // Completed quest pills (horizontal scroll if many)
      if !progress.completedQuestsOrdered.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: AppTheme.Space.xs) {
            ForEach(progress.completedQuestsOrdered) { quest in
              completedQuestChip(quest)
            }
          }
        }
      }
    }
  }

  private var progressTitle: String {
    if progress.isComplete {
      return "All done!"
    } else if progress.completedCount == 0 {
      return "Your Kitchen Tour"
    } else {
      return "Keep going"
    }
  }

  private var progressSubtitle: String {
    if progress.isComplete {
      return "You\u{2019}ve explored everything. Enjoy cooking!"
    } else if progress.completedCount == 0 {
      return "\(progress.totalCount) quick quests to discover FridgeLuck."
    } else {
      return
        "\(progress.totalCount - progress.completedCount) quest\(progress.totalCount - progress.completedCount == 1 ? "" : "s") remaining."
    }
  }

  private func completedQuestChip(_ quest: TutorialQuest) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Image(systemName: "checkmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(quest.accentColor)

      Text(quest.title)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.chipVertical)
    .background(quest.accentColor.opacity(0.10), in: Capsule())
  }
}
