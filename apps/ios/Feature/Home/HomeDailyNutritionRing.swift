import SwiftUI

struct HomeDailyNutritionRing: View {
  let caloriesConsumed: Double
  let calorieGoal: Double
  let proteinCurrent: Double
  let proteinGoal: Double
  let carbsCurrent: Double
  let carbsGoal: Double
  let fatCurrent: Double
  let fatGoal: Double
  let onTap: () -> Void

  private var caloriesRemaining: Int {
    max(Int(calorieGoal - caloriesConsumed), 0)
  }

  private var calorieProgress: Double {
    guard calorieGoal > 0 else { return 0 }
    return min(caloriesConsumed / calorieGoal, 1.0)
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: AppTheme.Space.lg) {
        FLProgressRing(
          progress: calorieProgress,
          size: AppTheme.Space.ringCompactSize,
          lineWidth: 8,
          fillColor: AppTheme.accent
        ) {
          Image(systemName: "flame.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }

        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xxs) {
            Text("\(caloriesRemaining)")
              .font(AppTheme.Typography.dataMedium)
              .foregroundStyle(AppTheme.textPrimary)
              .contentTransition(.numericText())
            Text("cal left")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }

          VStack(spacing: AppTheme.Space.xxs) {
            macroBar(
              label: "P", current: proteinCurrent, goal: proteinGoal, color: AppTheme.macroProtein)
            macroBar(label: "C", current: carbsCurrent, goal: carbsGoal, color: AppTheme.macroCarbs)
            macroBar(label: "F", current: fatCurrent, goal: fatGoal, color: AppTheme.macroFat)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
      }
      .padding(AppTheme.Space.md)
      .background(
        AppTheme.surface,
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
          .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
      )
    }
    .buttonStyle(FLPressableButtonStyle())
    .accessibilityLabel("\(caloriesRemaining) calories remaining today. Tap to see Progress.")
  }

  private func macroBar(label: String, current: Double, goal: Double, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Text(label)
        .font(.system(.caption2, design: .rounded, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 12, alignment: .leading)

      GeometryReader { geo in
        Capsule()
          .fill(color.opacity(0.15))
          .overlay(alignment: .leading) {
            Capsule()
              .fill(color)
              .frame(width: geo.size.width * min(goal > 0 ? current / goal : 0, 1.0))
          }
      }
      .frame(height: 4)
    }
  }
}
