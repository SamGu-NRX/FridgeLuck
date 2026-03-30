import SwiftUI

struct FLStreakBadge: View {
  static let milestoneThresholds: Set<Int> = [7, 14, 30, 60, 100]
  private static let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

  let currentStreak: Int
  let weekActivity: [Bool]
  var isMilestone: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var milestoneScale: CGFloat = 1.0

  var body: some View {
    VStack(spacing: AppTheme.Space.xs) {
      HStack(spacing: AppTheme.Space.xxs) {
        Image(systemName: "flame.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(AppTheme.accent)

        Text("\(currentStreak)")
          .font(AppTheme.Typography.dataMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())

        Text("d")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .padding(.horizontal, AppTheme.Space.sm)
      .padding(.vertical, AppTheme.Space.chipVertical)
      .background(AppTheme.accentMuted, in: Capsule())
      .scaleEffect(milestoneScale)

      HStack(spacing: 6) {
        ForEach(0..<min(weekActivity.count, 7), id: \.self) { index in
          VStack(spacing: 2) {
            Circle()
              .fill(weekActivity[index] ? AppTheme.accent : AppTheme.surfaceMuted)
              .frame(width: 7, height: 7)
            Text(Self.dayLabels[index])
              .font(.system(size: 8, weight: .medium, design: .rounded))
              .foregroundStyle(
                weekActivity[index]
                  ? AppTheme.accent
                  : AppTheme.textSecondary.opacity(0.45)
              )
          }
        }
      }
    }
    .onAppear {
      if isMilestone && !reduceMotion {
        withAnimation(AppMotion.streakCelebration) {
          milestoneScale = 1.12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          withAnimation(AppMotion.streakCelebration) {
            milestoneScale = 1.0
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(currentStreak) day streak, \(weekActivity.filter { $0 }.count) of 7 days active this week"
    )
  }
}
