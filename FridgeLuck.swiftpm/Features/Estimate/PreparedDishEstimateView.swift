import SwiftUI

/// Template-based estimation flow for prepared dishes when ingredient-level matching is weak.
struct PreparedDishEstimateView: View {
  @EnvironmentObject var deps: AppDependencies

  @State private var templates: [DishTemplate] = []
  @State private var selectedTemplateId: Int64?
  @State private var portionSize: DishPortionSize = .normal
  @State private var loadError: String?

  private var selectedTemplate: DishTemplate? {
    guard let selectedTemplateId else { return templates.first }
    return templates.first(where: { $0.id == selectedTemplateId }) ?? templates.first
  }

  private var estimate: PreparedDishEstimate? {
    guard let selectedTemplate else { return nil }
    return deps.dishEstimateService.estimate(template: selectedTemplate, size: portionSize)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppTheme.Space.sectionBreak) {
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          FLSectionHeader("Dish Template", subtitle: "Choose a dish type", icon: "fork.knife")

          if templates.isEmpty {
            Text(loadError ?? "No templates available.")
              .font(AppTheme.Typography.bodyMedium)
              .foregroundStyle(AppTheme.textSecondary)
          } else {
            Picker(
              "Dish",
              selection: Binding(
                get: { selectedTemplate?.id ?? templates.first?.id ?? 0 },
                set: { selectedTemplateId = $0 }
              )
            ) {
              ForEach(templates, id: \.id) { template in
                Text(template.name).tag(template.id ?? 0)
              }
            }
            .tint(AppTheme.accent)
          }
        }

        FLWaveDivider()

        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          FLSectionHeader("Portion Size", icon: "scalemass")

          Picker("Size", selection: $portionSize) {
            ForEach(DishPortionSize.allCases, id: \.self) { size in
              Text(size.displayName).tag(size)
            }
          }
          .pickerStyle(.segmented)
        }

        if let estimate {
          FLWaveDivider()

          VStack(alignment: .leading, spacing: AppTheme.Space.md) {
            FLSectionHeader(
              "Estimated Nutrition", subtitle: "Approximate values", icon: "flame.fill")

            VStack(spacing: AppTheme.Space.sm) {
              estimateRow(
                title: "Calories", range: estimate.calories, unit: "kcal",
                color: AppTheme.accent)
              estimateRow(
                title: "Protein", range: estimate.protein, unit: "g", color: AppTheme.sage)
              estimateRow(
                title: "Carbs", range: estimate.carbs, unit: "g", color: AppTheme.oat)
              estimateRow(
                title: "Fat", range: estimate.fat, unit: "g", color: AppTheme.accentLight)
            }
          }

          FLWaveDivider()

          VStack(alignment: .leading, spacing: AppTheme.Space.md) {
            FLSectionHeader("Macro Split", icon: "chart.bar.fill")

            macroSplitBar(estimate: estimate)
              .frame(height: 10)

            HStack(spacing: AppTheme.Space.md) {
              keyDot(color: AppTheme.sage, title: "Protein")
              keyDot(color: AppTheme.oat, title: "Carbs")
              keyDot(color: AppTheme.accentLight, title: "Fat")
            }
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.page)
      .padding(.vertical, AppTheme.Space.md)
    }
    .navigationTitle("Dish Estimate")
    .navigationBarTitleDisplayMode(.inline)
    .flPageBackground()
    .task {
      loadTemplates()
    }
  }

  private func loadTemplates() {
    do {
      templates = try deps.dishEstimateService.templates()
      if selectedTemplateId == nil {
        selectedTemplateId = templates.first?.id
      }
    } catch {
      loadError = error.localizedDescription
    }
  }

  private func estimateRow(
    title: String,
    range: NutrientRange,
    unit: String,
    color: Color
  ) -> some View {
    HStack {
      HStack(spacing: AppTheme.Space.chipVertical) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(title)
          .font(AppTheme.Typography.bodyMedium)
      }
      Spacer()
      Text("\(Int(range.min.rounded()))\u{2013}\(Int(range.max.rounded())) \(unit)")
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
    }
  }

  private func macroSplitBar(estimate: PreparedDishEstimate) -> some View {
    let protein = midpoint(estimate.protein) * 4
    let carbs = midpoint(estimate.carbs) * 4
    let fat = midpoint(estimate.fat) * 9
    let total = max(1, protein + carbs + fat)

    return GeometryReader { geo in
      HStack(spacing: AppTheme.Space.xxxs) {
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.sage)
          .frame(width: geo.size.width * (protein / total))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.oat)
          .frame(width: geo.size.width * (carbs / total))
        RoundedRectangle(cornerRadius: 4)
          .fill(AppTheme.accentLight)
          .frame(width: geo.size.width * (fat / total))
      }
      .clipShape(Capsule())
    }
  }

  private func keyDot(color: Color, title: String) -> some View {
    HStack(spacing: AppTheme.Space.xxs) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(title)
    }
  }

  private func midpoint(_ range: NutrientRange) -> Double {
    (range.min + range.max) / 2.0
  }
}
