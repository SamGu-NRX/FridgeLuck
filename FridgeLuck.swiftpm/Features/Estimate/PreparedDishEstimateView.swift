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
    List {
      Section("Dish Template") {
        if templates.isEmpty {
          Text(loadError ?? "No templates available.")
            .foregroundStyle(.secondary)
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
        }
      }

      Section("Portion Size") {
        Picker("Size", selection: $portionSize) {
          ForEach(DishPortionSize.allCases, id: \.self) { size in
            Text(size.displayName).tag(size)
          }
        }
        .pickerStyle(.segmented)
      }

      if let estimate {
        Section("Estimated Nutrition Range") {
          Text("Approximate values only")
            .font(.caption)
            .foregroundStyle(.secondary)

          estimateRow(
            title: "Calories",
            range: estimate.calories,
            unit: "kcal",
            color: .orange
          )
          estimateRow(
            title: "Protein",
            range: estimate.protein,
            unit: "g",
            color: .blue
          )
          estimateRow(
            title: "Carbs",
            range: estimate.carbs,
            unit: "g",
            color: .green
          )
          estimateRow(
            title: "Fat",
            range: estimate.fat,
            unit: "g",
            color: .red
          )
        }

        Section("Macro Split") {
          macroSplitBar(estimate: estimate)
            .frame(height: 10)
          HStack(spacing: 12) {
            keyDot(color: .blue, title: "Protein")
            keyDot(color: .green, title: "Carbs")
            keyDot(color: .red, title: "Fat")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Dish Estimate")
    .navigationBarTitleDisplayMode(.inline)
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
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(title)
      }
      Spacer()
      Text("\(Int(range.min.rounded()))-\(Int(range.max.rounded())) \(unit)")
        .fontWeight(.semibold)
    }
  }

  private func macroSplitBar(estimate: PreparedDishEstimate) -> some View {
    let protein = midpoint(estimate.protein) * 4
    let carbs = midpoint(estimate.carbs) * 4
    let fat = midpoint(estimate.fat) * 9
    let total = max(1, protein + carbs + fat)

    return GeometryReader { geo in
      HStack(spacing: 2) {
        RoundedRectangle(cornerRadius: 4)
          .fill(.blue)
          .frame(width: geo.size.width * (protein / total))
        RoundedRectangle(cornerRadius: 4)
          .fill(.green)
          .frame(width: geo.size.width * (carbs / total))
        RoundedRectangle(cornerRadius: 4)
          .fill(.red)
          .frame(width: geo.size.width * (fat / total))
      }
      .clipShape(Capsule())
    }
  }

  private func keyDot(color: Color, title: String) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(title)
    }
  }

  private func midpoint(_ range: NutrientRange) -> Double {
    (range.min + range.max) / 2.0
  }
}
