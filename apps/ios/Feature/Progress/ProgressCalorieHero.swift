import SwiftUI

struct ProgressCalorieHero: View {
  let consumed: Double
  let goal: Double
  let goalLabel: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var appeared = false

  private var remaining: Int {
    max(Int((goal - consumed).rounded()), 0)
  }

  private var isOver: Bool {
    consumed > goal
  }

  private var overAmount: Int {
    Int((consumed - goal).rounded())
  }

  private var progress: Double {
    guard goal > 0 else { return 0 }
    return min(consumed / goal, 1.0)
  }

  var body: some View {
    FLCard {
      HStack(spacing: AppTheme.Space.lg) {
        // Text stack — left
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          // Hero number
          VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
            Text(isOver ? "\(overAmount)" : "\(remaining)")
              .font(AppTheme.Typography.dataHero)
              .foregroundStyle(isOver ? AppTheme.accent : AppTheme.textPrimary)
              .contentTransition(.numericText())
              .animation(reduceMotion ? nil : AppMotion.counterReveal, value: remaining)

            Text(isOver ? "Calories over" : "Calories left")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
          }

          // Goal context
          HStack(spacing: AppTheme.Space.xxs) {
            Text("\(Int(consumed.rounded()))")
              .font(AppTheme.Typography.dataSmall)
              .foregroundStyle(AppTheme.textPrimary)
            Text("/ \(Int(goal.rounded())) cal")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }

          // Goal type pill
          if !goalLabel.isEmpty {
            Text(goalLabel)
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.sage)
              .padding(.horizontal, AppTheme.Space.xs)
              .padding(.vertical, AppTheme.Space.xxs)
              .background(AppTheme.sage.opacity(0.16), in: Capsule())
          }
        }

        Spacer(minLength: 0)

        // Ring — right, with subtle ambient glow in dark mode
        ZStack {
          if colorScheme == .dark {
            Circle()
              .fill(
                RadialGradient(
                  colors: [AppTheme.accent.opacity(0.08), Color.clear],
                  center: .center,
                  startRadius: AppTheme.Space.ringHeroSize * 0.3,
                  endRadius: AppTheme.Space.ringHeroSize * 0.75
                )
              )
              .frame(
                width: AppTheme.Space.ringHeroSize + 32,
                height: AppTheme.Space.ringHeroSize + 32
              )
          }

          FLProgressRing(
            progress: appeared ? progress : 0,
            size: AppTheme.Space.ringHeroSize,
            lineWidth: 12,
            fillColor: AppTheme.accent,
            animateOnAppear: false
          ) {
            Image(systemName: "flame.fill")
              .font(.system(size: 24, weight: .semibold))
              .foregroundStyle(AppTheme.accent)
          }
        }
      }
    }
    .onAppear {
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.ringFillProgress) {
          appeared = true
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      isOver
        ? "\(overAmount) calories over your \(Int(goal.rounded())) calorie goal"
        : "\(remaining) calories remaining of \(Int(goal.rounded())) calorie goal"
    )
  }
}
