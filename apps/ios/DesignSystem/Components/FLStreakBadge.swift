import SwiftUI

struct FLStreakBadge: View {
  static let milestoneThresholds: Set<Int> = [7, 14, 30, 60, 100]

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

      HStack(spacing: AppTheme.Space.xxs) {
        ForEach(0..<min(weekActivity.count, 7), id: \.self) { index in
          Circle()
            .fill(weekActivity[index] ? AppTheme.accent : AppTheme.surfaceMuted)
            .frame(width: 8, height: 8)
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
