import Charts
import SwiftUI

struct ProgressWeeklyTrendSection: View {
  let weeklyMacros: [DailyMacroPoint]
  let dailyCalorieGoal: Double
  let insightText: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      FLSectionHeader("This Week", subtitle: "Daily calorie intake", icon: "chart.bar.fill")

      if weeklyMacros.isEmpty {
        emptyChart
      } else {
        chartCard
      }

      if let insightText, !insightText.isEmpty {
        insightRow(text: insightText)
      }
    }
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 10)
    .onAppear {
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 7)) {
          appeared = true
        }
      }
    }
  }

  // MARK: - Chart

  private var chartCard: some View {
    FLCard {
      Chart {
        ForEach(weeklyMacros) { point in
          BarMark(
            x: .value("Day", point.date, unit: .day),
            y: .value("Calories", point.calories)
          )
          .foregroundStyle(
            .linearGradient(
              colors: [AppTheme.chartBarBottom, AppTheme.chartBarTop],
              startPoint: .bottom,
              endPoint: .top
            )
          )
          .cornerRadius(4)
        }

        RuleMark(y: .value("Goal", dailyCalorieGoal))
          .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
          .foregroundStyle(AppTheme.chartLine.opacity(0.6))
          .annotation(position: .top, alignment: .trailing) {
            Text("Goal")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.chartLine)
          }
      }
      .chartXAxis {
        AxisMarks(values: .stride(by: .day)) { _ in
          AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading) { _ in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            .foregroundStyle(AppTheme.oat.opacity(0.3))
          AxisValueLabel()
            .foregroundStyle(AppTheme.textSecondary)
        }
      }
      .frame(height: 180)
    }
  }

  private var emptyChart: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "chart.bar.fill")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.oat.opacity(0.4))
        Text("Cook a meal to start tracking!")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.xl)
    }
  }

  // MARK: - Insight

  private func insightRow(text: String) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(AppTheme.sage)

      Text(text)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(AppTheme.sage)
    }
    .padding(AppTheme.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      AppTheme.sage.opacity(0.08),
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
  }
}
