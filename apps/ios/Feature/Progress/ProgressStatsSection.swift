import SwiftUI

struct ProgressStatsSection: View {
  let snapshot: ProgressSnapshot

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      Text("BY THE NUMBERS")
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
        .kerning(1.5)

      HStack(spacing: 0) {
        FLStatDisplay(value: "\(snapshot.currentStreak)", label: "day streak")
        statDivider
        FLStatDisplay(value: "\(snapshot.totalMealsCooked)", label: "total meals")
        statDivider
        FLStatDisplay(value: "\(snapshot.totalRecipesUsed)", label: "recipes used")
      }

      if let avg = snapshot.averageRating {
        HStack(spacing: AppTheme.Space.xs) {
          Image(systemName: "star.fill")
            .font(.system(size: 14))
            .foregroundStyle(AppTheme.accent)
          Text(String(format: "%.1f", avg))
            .font(AppTheme.Typography.dataSmall)
            .foregroundStyle(AppTheme.textPrimary)
          Text("avg rating")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .onAppear {
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 8)) {
          appeared = true
        }
      }
    }
  }

  private var statDivider: some View {
    Rectangle()
      .fill(AppTheme.oat.opacity(0.30))
      .frame(width: 1, height: AppTheme.Home.statDividerHeight)
  }
}
