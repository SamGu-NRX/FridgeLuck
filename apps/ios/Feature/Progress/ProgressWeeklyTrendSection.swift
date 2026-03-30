import Charts
import SwiftUI

struct ProgressWeeklyTrendSection: View {
  let weeklyMacros: [DailyMacroPoint]
  let dailyCalorieGoal: Double
  let insightText: String?
  let onRangeChanged: (ChartRange) async -> [DailyMacroPoint]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var selectedRange: ChartRange = .week
  @State private var displayData: [DailyMacroPoint] = []

  private var chartData: [DailyMacroPoint] {
    selectedRange == .week ? weeklyMacros : displayData
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      FLSectionHeader(
        selectedRange.sectionTitle,
        subtitle: "Calorie intake",
        icon: "chart.line.uptrend.xyaxis"
      )

      rangePicker

      if chartData.isEmpty {
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
      displayData = weeklyMacros
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(AppMotion.staggerEntrance.delay(AppMotion.staggerInterval * 7)) {
          appeared = true
        }
      }
    }
  }

  private var rangePicker: some View {
    Picker("Range", selection: $selectedRange) {
      ForEach(ChartRange.allCases) { range in
        Text(range.label).tag(range)
      }
    }
    .pickerStyle(.segmented)
    .onChange(of: selectedRange) { _, newRange in
      Task {
        let data = await onRangeChanged(newRange)
        withAnimation(reduceMotion ? nil : AppMotion.chartReveal) {
          displayData = data
        }
      }
    }
  }

  private var chartCard: some View {
    FLCard {
      Chart {
        ForEach(chartData) { point in
          AreaMark(
            x: .value("Day", point.date, unit: .day),
            y: .value("Calories", point.calories)
          )
          .interpolationMethod(.catmullRom)
          .foregroundStyle(
            .linearGradient(
              colors: [AppTheme.accent.opacity(0.25), AppTheme.accent.opacity(0.03)],
              startPoint: .top,
              endPoint: .bottom
            )
          )

          LineMark(
            x: .value("Day", point.date, unit: .day),
            y: .value("Calories", point.calories)
          )
          .interpolationMethod(.catmullRom)
          .foregroundStyle(AppTheme.accent)
          .lineStyle(StrokeStyle(lineWidth: 2.2))
        }

        RuleMark(y: .value("Goal", dailyCalorieGoal))
          .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
          .foregroundStyle(AppTheme.chartLine.opacity(0.45))
          .annotation(position: .top, alignment: .trailing) {
            Text("Goal")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.chartLine.opacity(0.7))
          }
      }
      .chartXAxis {
        AxisMarks(values: xAxisValues) { _ in
          AxisValueLabel(format: xAxisLabelFormat)
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

  private var xAxisValues: AxisMarkValues {
    switch selectedRange {
    case .week:
      return .stride(by: .day)
    case .month:
      return .stride(by: .day, count: 7)
    case .threeMonths:
      return .stride(by: .month)
    }
  }

  private var xAxisLabelFormat: Date.FormatStyle {
    switch selectedRange {
    case .week:
      return .dateTime.weekday(.abbreviated)
    case .month:
      return .dateTime.month(.abbreviated).day()
    case .threeMonths:
      return .dateTime.month(.abbreviated)
    }
  }

  private var emptyChart: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "chart.line.uptrend.xyaxis")
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
