import SwiftUI

struct ProgressMacroRow: View {
  let todayMacros: MacroTotals
  let proteinGoal: Double
  let carbsGoal: Double
  let fatGoal: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    HStack(spacing: AppTheme.Space.sm) {
      FLMacroCard(
        name: "Protein",
        current: todayMacros.protein,
        goal: proteinGoal,
        unit: "g",
        color: AppTheme.macroProtein,
        animateOnAppear: appeared
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 8)

      FLMacroCard(
        name: "Carbs",
        current: todayMacros.carbs,
        goal: carbsGoal,
        unit: "g",
        color: AppTheme.macroCarbs,
        animateOnAppear: appeared
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 8)

      FLMacroCard(
        name: "Fat",
        current: todayMacros.fat,
        goal: fatGoal,
        unit: "g",
        color: AppTheme.macroFat,
        animateOnAppear: appeared
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 8)
    }
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance.delay(0.12)) {
          appeared = true
        }
      }
    }
  }
}

// MARK: - Today's Macros Detail Card

struct ProgressMacroDetailCard: View {
  let todayMacros: MacroTotals
  let proteinGoal: Double
  let carbsGoal: Double
  let fatGoal: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        macroProgressRow(
          label: "Protein",
          current: todayMacros.protein,
          goal: proteinGoal,
          unit: "g",
          color: AppTheme.macroProtein
        )
        macroProgressRow(
          label: "Carbs",
          current: todayMacros.carbs,
          goal: carbsGoal,
          unit: "g",
          color: AppTheme.macroCarbs
        )
        macroProgressRow(
          label: "Fat",
          current: todayMacros.fat,
          goal: fatGoal,
          unit: "g",
          color: AppTheme.macroFat
        )
      }
    }
  }

  private func macroProgressRow(
    label: String,
    current: Double,
    goal: Double,
    unit: String,
    color: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xxs) {
      HStack {
        Text(label)
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text("\(Int(current.rounded()))\(unit) / \(Int(goal.rounded()))\(unit)")
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
      }
      GeometryReader { geo in
        let pct = goal > 0 ? min(current / goal, 1.0) : 0
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(height: 8)
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: geo.size.width * pct, height: 8)
            .animation(reduceMotion ? nil : AppMotion.chartReveal, value: pct)
        }
      }
      .frame(height: 8)
    }
  }
}
