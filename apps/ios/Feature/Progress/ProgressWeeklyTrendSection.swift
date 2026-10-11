import Charts
import SwiftUI

/// The trend chart section. Presentation state (selected range, in-flight
/// load, shown reading) is owned by the view model's coordinator — this
/// view renders it and reports selections back; it keeps no chart state of
/// its own.
struct ProgressWeeklyTrendSection: View {
  let state: ProgressRangeState
  let dailyCalorieGoal: Double
  let insightText: String?
  let onSelect: (ChartRange) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  /// Known days only — a day with no data is never plotted as zero.
  private var chartData: [DailyMacroPoint] {
    guard let shown = state.shown else { return [] }
    return shown.days.compactMap { point in
      guard let value = point.value else { return nil }
      return DailyMacroPoint(
        date: point.date,
        calories: value.calories,
        protein: value.protein,
        carbs: value.carbs,
        fat: value.fat
      )
    }
  }

  /// Visible source label — a source switch is always announced, and the
  /// two sources are never blended in one chart.
  private var subtitle: String {
    var parts = ["Calorie intake"]
    if let shown = state.shown {
      parts.append("\(shown.coverageSummary) · from \(ProgressSourceNotes.sourceName(shown.source))")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      FLSectionHeader(
        state.selectedRange.sectionTitle,
        subtitle: subtitle,
        icon: "chart.line.uptrend.xyaxis"
      )

      rangePicker

      if chartData.isEmpty {
        emptyChart
      } else {
        chartCard
      }

      if let reason = state.shown?.fallbackReason {
        fallbackRow(reason: reason)
      }

      if let error = state.errorMessage {
        errorRow(message: error)
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

  private var rangePicker: some View {
    Picker("Range", selection: Binding(
      get: { state.selectedRange },
      set: { onSelect($0) }
    )) {
      ForEach(ChartRange.allCases) { range in
        Text(range.label).tag(range)
      }
    }
    .pickerStyle(.segmented)
    .accessibilityLabel("Trend range")
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
    .accessibilityLabel(
      "Calorie trend for \(state.selectedRange.sectionTitle). \(subtitle)."
    )
  }

  private var xAxisValues: AxisMarkValues {
    switch state.selectedRange {
    case .week:
      return .stride(by: .day)
    case .month:
      return .stride(by: .day, count: 7)
    case .threeMonths:
      return .stride(by: .month)
    }
  }

  private var xAxisLabelFormat: Date.FormatStyle {
    switch state.selectedRange {
    case .week:
      return .dateTime.weekday(.abbreviated)
    case .month:
      return .dateTime.month(.abbreviated).day()
    case .threeMonths:
      return .dateTime.month(.abbreviated)
    }
  }

  /// Distinct treatment for "no data yet" — not a zero-height chart.
  private var emptyChart: some View {
    FLCard {
      VStack(spacing: AppTheme.Space.md) {
        Image(systemName: "chart.line.uptrend.xyaxis")
          .font(.system(size: 28))
          .foregroundStyle(AppTheme.oat.opacity(0.4))
        Text(state.isLoading ? "Loading your trend…" : "Cook a meal to start tracking!")
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.xl)
    }
  }

  private func fallbackRow(reason: String) -> some View {
    row(
      text: "\(reason) — showing your meal log instead.",
      icon: "arrow.triangle.branch",
      color: AppTheme.accent)
  }

  private func errorRow(message: String) -> some View {
    row(text: message, icon: "exclamationmark.triangle.fill", color: AppTheme.accent)
  }

  private func insightRow(text: String) -> some View {
    row(text: text, icon: "lightbulb.fill", color: AppTheme.sage)
      .background(
        AppTheme.sage.opacity(0.08),
        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
  }

  private func row(text: String, icon: String, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)

      Text(text)
        .font(AppTheme.Typography.bodySmall)
        .foregroundStyle(color)
    }
    .padding(AppTheme.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
