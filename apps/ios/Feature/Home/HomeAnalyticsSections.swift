import Charts
import SwiftUI

enum HomeInsightMode: String, CaseIterable, Identifiable {
  case macros = "Macros"
  case cadence = "Cadence"

  var id: String { rawValue }
}

struct HomeInsightSection: View {
  @Binding var insightMode: HomeInsightMode
  let snapshot: HomeDashboardSnapshot

  var body: some View {
    let profile = snapshot.healthProfile ?? .default
    let slices = macroSlices(for: profile)

    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack {
        VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
          Text("Insights")
            .font(AppTheme.Typography.displayCaption)
            .foregroundStyle(AppTheme.textPrimary)
          Text(insightMode == .macros ? "Target macro split" : "Weekly cooking cadence")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer()
        Image(systemName: insightMode == .macros ? "chart.pie.fill" : "chart.bar.fill")
          .foregroundStyle(AppTheme.accent)
          .font(.system(size: 16, weight: .medium))
      }

      Picker("Insight mode", selection: $insightMode) {
        ForEach(HomeInsightMode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if insightMode == .macros {
        ZStack {
          Chart(slices) { slice in
            SectorMark(
              angle: .value("Percent", slice.value),
              innerRadius: .ratio(0.68),
              angularInset: 2.0
            )
            .foregroundStyle(color(for: slice.color))
            .cornerRadius(4)
          }
          .chartLegend(.hidden)
          .frame(height: 190)

          VStack(spacing: AppTheme.Space.xxxs) {
            Text("\(profile.dailyCalories ?? HealthProfile.default.dailyCalories ?? 2000)")
              .font(AppTheme.Typography.displayCaption)
              .foregroundStyle(AppTheme.textPrimary)
            Text("daily target")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }
        }

        HStack(spacing: AppTheme.Space.sm) {
          legendChip(title: "Protein", color: AppTheme.chartProtein)
          legendChip(title: "Carbs", color: AppTheme.chartCarbs)
          legendChip(title: "Fat", color: AppTheme.chartFat)
        }
      } else {
        Chart(snapshot.weekdayDistribution) { point in
          BarMark(
            x: .value("Day", point.weekdayLabel),
            y: .value("Meals", point.meals)
          )
          .foregroundStyle(
            .linearGradient(
              colors: [AppTheme.chartBarBottom, AppTheme.chartBarTop],
              startPoint: .bottom,
              endPoint: .top
            )
          )
          .cornerRadius(5)
        }
        .chartYAxis {
          AxisMarks(values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 3]))
              .foregroundStyle(AppTheme.oat.opacity(0.20))
          }
        }
        .chartXAxis {
          AxisMarks { value in
            AxisValueLabel {
              if let label = value.as(String.self) {
                Text(label)
                  .font(AppTheme.Typography.labelSmall)
                  .foregroundStyle(AppTheme.textSecondary)
              }
            }
          }
        }
        .frame(height: 180)
      }
    }
  }

  private func macroSlices(for profile: HealthProfile) -> [MacroTargetSlice] {
    [
      MacroTargetSlice(name: "Protein", value: profile.proteinPct * 100, color: .protein),
      MacroTargetSlice(name: "Carbs", value: profile.carbsPct * 100, color: .carbs),
      MacroTargetSlice(name: "Fat", value: profile.fatPct * 100, color: .fat),
    ]
  }

  private func color(for token: MacroTargetSlice.ColorToken) -> Color {
    switch token {
    case .protein: return AppTheme.chartProtein
    case .carbs: return AppTheme.chartCarbs
    case .fat: return AppTheme.chartFat
    }
  }

  private func legendChip(title: String, color: Color) -> some View {
    HStack(spacing: AppTheme.Space.xs) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(title)
        .font(AppTheme.Typography.labelSmall)
        .foregroundStyle(AppTheme.textSecondary)
    }
    .padding(.horizontal, AppTheme.Space.sm)
    .padding(.vertical, AppTheme.Space.xs)
    .background(AppTheme.surfaceMuted, in: Capsule())
  }
}
