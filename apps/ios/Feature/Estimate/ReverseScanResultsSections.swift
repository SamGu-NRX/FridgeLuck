import SwiftUI

// MARK: - Portion Size

enum MealPortionSize: String, CaseIterable {
  case small
  case normal
  case large

  var label: String {
    switch self {
    case .small: return "Small"
    case .normal: return "Normal"
    case .large: return "Large"
    }
  }

  var multiplier: Double {
    switch self {
    case .small: return 0.7
    case .normal: return 1.0
    case .large: return 1.4
    }
  }

  var hint: String {
    switch self {
    case .small: return "~70%"
    case .normal: return "100%"
    case .large: return "~140%"
    }
  }
}

// MARK: - Ingredient Breakdown Section

struct ReverseScanIngredientBreakdownSection: View {
  let analysis: ReverseScanAnalysis
  let candidateRecipe: ReverseScanRecipeCandidate?
  let portionMultiplier: Double
  let servings: Int

  @EnvironmentObject var deps: AppDependencies

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Ingredient Breakdown")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          Text("\(ingredientRows.count) items")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        if ingredientRows.isEmpty {
          Text("No ingredient details available for this recipe.")
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        } else {
          VStack(spacing: AppTheme.Space.xs) {
            ForEach(Array(ingredientRows.enumerated()), id: \.element.ingredientId) {
              index, row in
              ingredientRow(row)
              if index < ingredientRows.count - 1 {
                Divider()
              }
            }
          }
        }
      }
    }
  }

  private struct IngredientRowData {
    let ingredientId: Int64
    let name: String
    let baseGrams: Double
    let scaledGrams: Double
    let confidence: Float
  }

  private var ingredientRows: [IngredientRowData] {
    guard candidateRecipe != nil else {
      return analysis.detections.prefix(12).map { detection in
        IngredientRowData(
          ingredientId: detection.ingredientId,
          name: detection.label,
          baseGrams: 100,
          scaledGrams: 100 * portionMultiplier * Double(servings),
          confidence: detection.confidence
        )
      }
    }

    return analysis.detections.prefix(12).map { detection in
      let baseGrams: Double = 100
      let scaledGrams = baseGrams * portionMultiplier * Double(servings)
      return IngredientRowData(
        ingredientId: detection.ingredientId,
        name: detection.label,
        baseGrams: baseGrams,
        scaledGrams: scaledGrams,
        confidence: detection.confidence
      )
    }
  }

  private func ingredientRow(_ row: IngredientRowData) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(row.name)
          .font(AppTheme.Typography.bodyMedium)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(1)
      }

      Spacer()

      HStack(spacing: AppTheme.Space.xs) {
        Text("\(Int(row.scaledGrams.rounded()))g")
          .font(AppTheme.Typography.dataSmall)
          .foregroundStyle(AppTheme.textPrimary)
          .contentTransition(.numericText())

        confidenceIndicator(row.confidence)
      }
    }
    .padding(.vertical, AppTheme.Space.xxxs)
  }

  private func confidenceIndicator(_ confidence: Float) -> some View {
    Circle()
      .fill(
        confidence >= 0.8 ? AppTheme.sage : confidence >= 0.5 ? AppTheme.oat : AppTheme.dustyRose
      )
      .frame(width: 6, height: 6)
  }
}

// MARK: - Portion Controls

struct ReverseScanPortionControls: View {
  @Binding var portionSize: MealPortionSize

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack {
        Text("Portion Size")
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text(portionSize.hint)
          .font(AppTheme.Typography.labelSmall)
          .foregroundStyle(AppTheme.accent)
          .contentTransition(.numericText())
      }

      Picker("Portion", selection: $portionSize) {
        ForEach(MealPortionSize.allCases, id: \.self) { size in
          Text(size.label).tag(size)
        }
      }
      .pickerStyle(.segmented)
    }
    .padding(AppTheme.Space.md)
    .background(
      AppTheme.surface,
      in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
        .stroke(AppTheme.oat.opacity(0.25), lineWidth: 1)
    )
  }
}

// MARK: - Inventory Deduction Preview

struct ReverseScanDeductionPreviewSection: View {
  let previews: [InventoryDeductionPreview]

  @ViewBuilder
  var body: some View {
    if !previews.isEmpty {
      FLCard(tone: .warm) {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          HStack {
            Image(systemName: "arrow.down.doc")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(AppTheme.accent)
            Text("Inventory Deduction")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("\(previews.count) items")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
          }

          VStack(spacing: AppTheme.Space.xs) {
            ForEach(previews) { preview in
              deductionRow(preview)
            }
          }

          let shortfalls = previews.filter(\.hasShortfall)
          if !shortfalls.isEmpty {
            HStack(spacing: AppTheme.Space.xxs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.warning)
              Text(
                "\(shortfalls.count) item\(shortfalls.count == 1 ? "" : "s") not fully in stock"
              )
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.warning)
            }
          }
        }
      }
    }
  }

  private func deductionRow(_ preview: InventoryDeductionPreview) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      VStack(alignment: .leading, spacing: AppTheme.Space.xxxs) {
        Text(preview.ingredientName)
          .font(AppTheme.Typography.bodySmall)
          .foregroundStyle(AppTheme.textPrimary)
          .lineLimit(1)

        HStack(spacing: AppTheme.Space.xxs) {
          Text("Deduct \(Int(preview.proposedGrams.rounded()))g")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(AppTheme.accent)
            .contentTransition(.numericText())

          Text("·")
            .foregroundStyle(AppTheme.textSecondary)

          Text("\(Int(preview.availableGrams.rounded()))g available")
            .font(AppTheme.Typography.labelSmall)
            .foregroundStyle(
              preview.hasShortfall ? AppTheme.warning : AppTheme.textSecondary
            )
            .contentTransition(.numericText())
        }
      }

      Spacer()

      coverageBar(ratio: preview.coverageRatio)
    }
    .padding(.vertical, AppTheme.Space.xxxs)
  }

  private func coverageBar(ratio: Double) -> some View {
    ZStack(alignment: .leading) {
      Capsule()
        .fill(AppTheme.surfaceMuted)
        .frame(width: 40, height: 4)
      Capsule()
        .fill(ratio >= 1.0 ? AppTheme.sage : ratio >= 0.5 ? AppTheme.oat : AppTheme.dustyRose)
        .frame(width: max(2, 40 * ratio), height: 4)
    }
  }
}
