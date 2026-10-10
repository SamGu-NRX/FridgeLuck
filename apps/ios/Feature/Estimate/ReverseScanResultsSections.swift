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

/// One ingredient of the meal being logged, in the amount the log will count.
struct MealBreakdownRow: Equatable {
  let ingredientId: Int64
  let name: String
  let grams: Double
}

/// What the Ingredient Breakdown card can truthfully say. It used to list each detection at an
/// invented 100 g whether or not a recipe was chosen, and "No ingredient details available for
/// this recipe" when nothing was detected, even before a recipe existed.
enum MealBreakdownContent: Equatable {
  case noRecipe
  case loading
  case noIngredientList
  case ingredients([MealBreakdownRow])

  var message: String? {
    switch self {
    case .noRecipe: return "Choose a recipe to see what's in it."
    case .loading: return nil
    case .noIngredientList: return "No ingredient amounts to show for this recipe."
    case .ingredients: return "Scaled to your servings and portion."
    }
  }

  /// `loadedIngredients` is nil until the chosen recipe's ingredients have been read.
  /// Only required ingredients are listed, with the scaling `InventoryRepository.applyConsumption`
  /// uses, because macros (`NutritionService`) and deduction count only those.
  static func make(
    recipe: Recipe?,
    loadedIngredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]?,
    servingsConsumed: Int,
    portionMultiplier: Double
  ) -> MealBreakdownContent {
    guard let recipe else { return .noRecipe }
    guard recipe.id != nil else { return .noIngredientList }
    guard let loadedIngredients else { return .loading }

    let factor = InventoryRepository.servingFactor(
      servingsConsumed: max(1, servingsConsumed),
      portionMultiplier: portionMultiplier,
      recipeServings: recipe.servings
    )
    let rows = loadedIngredients
      .filter { $0.quantity.isRequired }
      .map {
        MealBreakdownRow(
          ingredientId: $0.quantity.ingredientId,
          name: $0.ingredient.displayName,
          grams: $0.quantity.quantityGrams * factor
        )
      }
    return rows.isEmpty ? .noIngredientList : .ingredients(rows)
  }
}

// MARK: - Logged Message

/// The "Meal logged" alert text, built from what `MealLogService.logMeal` actually took out of
/// inventory. It used to say "inventory updated" even when nothing was consumed.
enum MealLoggedMessage {
  static func text(for consumption: [InventoryConsumptionResult]) -> String {
    let used = consumption.filter { $0.consumedGrams > 0 }.count
    if used > 0 {
      return
        "Your meal has been recorded, and \(used) ingredient\(used == 1 ? "" : "s") came out of your Kitchen."
    }
    // Empty or all-zero consumption has several causes (no ingredients, only optional ones,
    // zero-gram rows, nothing in stock) that the results can't tell apart, so don't name one.
    return "Your meal has been recorded. Your Kitchen didn't change."
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
          Text("Deduct \(Int(preview.deductedGrams.rounded()))g")
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
