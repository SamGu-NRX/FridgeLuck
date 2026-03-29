import SwiftUI

struct FLMacroCard: View {
  let name: String
  let current: Double
  let goal: Double
  let unit: String
  let color: Color
  var animateOnAppear: Bool = true

  private var progress: Double {
    guard goal > 0 else { return 0 }
    return min(current / goal, 1.0)
  }

  private var remaining: Double {
    max(goal - current, 0)
  }

  private var isOver: Bool {
    current > goal
  }

  var body: some View {
    VStack(spacing: AppTheme.Space.xs) {
      FLProgressRing(
        progress: progress,
        size: AppTheme.Space.ringMacroSize,
        lineWidth: 6,
        trackColor: color.opacity(0.15),
        fillColor: color,
        animateOnAppear: animateOnAppear
      )

      VStack(spacing: AppTheme.Space.xxxs) {
        HStack(spacing: 0) {
          Text("\(Int(isOver ? current - goal : remaining))")
            .font(AppTheme.Typography.dataMedium)
            .foregroundStyle(AppTheme.textPrimary)
            .contentTransition(.numericText())
          Text(unit)
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        Text(isOver ? "\(name) over" : "\(name) left")
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(isOver ? AppTheme.accent : AppTheme.textSecondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, AppTheme.Space.sm)
    .padding(.horizontal, AppTheme.Space.xs)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.30), lineWidth: 1)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(name): \(Int(current)) of \(Int(goal)) \(unit). \(isOver ? "Over by \(Int(current - goal))" : "\(Int(goal - current)) \(unit) remaining")."
    )
  }
}
