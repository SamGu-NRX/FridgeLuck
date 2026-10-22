import FLFeatureLogic
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
  /// nil for a catalog line the ingredient bridge maps to no app ingredient.
  let ingredientId: Int64?
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

  /// A catalog recipe's rows: its required lines that state a weight, named by the catalog
  /// vocabulary and scaled over the catalog recipe's servings. A catalog pick has no
  /// `recipes.id` with ingredient rows, so the legacy `make` above always read "No ingredient
  /// amounts" for it.
  static func make(
    catalogPacket packet: RecipeCatalogCookPacket,
    servingsConsumed: Int,
    portionMultiplier: Double
  ) -> MealBreakdownContent {
    let factor = InventoryRepository.servingFactor(
      servingsConsumed: max(1, servingsConsumed),
      portionMultiplier: portionMultiplier,
      recipeServings: packet.servings
    )
    let rows = packet.lines.filter(\.required).compactMap { line -> MealBreakdownRow? in
      guard let grams = line.quantity.statedGrams, grams > 0 else { return nil }
      return MealBreakdownRow(
        ingredientId: line.bridgedIngredientId,
        name: RecipeRepository.catalogLineName(key: line.key, displayName: line.displayName),
        grams: grams * factor
      )
    }
    return rows.isEmpty ? .noIngredientList : .ingredients(rows)
  }
}

extension CookQuantity {
  /// The line's weight when the recipe gives one; nil for "to taste" and unweighed counts.
  fileprivate var statedGrams: Double? {
    switch self {
    case .grams(let grams): return grams
    case .household(_, _, let grams), .count(_, _, let grams): return grams
    case .unknown: return nil
    }
  }
}

struct ReverseScanIngredientBreakdownSection: View {
  /// The recipe the user chose, from the match list or the manual picker.
  let recipe: Recipe?
  /// Set when the choice is a catalog recipe, whose lines live in the catalog tables.
  let catalogId: String?
  let portionMultiplier: Double
  let servings: Int

  @EnvironmentObject var deps: AppDependencies
  @Environment(AppPreferencesStore.self) private var prefs
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var loaded:
    (recipeID: Int64, ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)])?
  /// The catalog id read and its packet; the packet is nil when the id isn't installed.
  @State private var loadedCatalog: (catalogId: String, packet: RecipeCatalogCookPacket?)?

  private var content: MealBreakdownContent {
    if recipe != nil, let catalogId {
      guard let loadedCatalog, loadedCatalog.catalogId == catalogId else { return .loading }
      guard let packet = loadedCatalog.packet else { return .noIngredientList }
      return MealBreakdownContent.make(
        catalogPacket: packet,
        servingsConsumed: servings,
        portionMultiplier: portionMultiplier
      )
    }
    return MealBreakdownContent.make(
      recipe: recipe,
      loadedIngredients: loaded.flatMap { $0.recipeID == recipe?.id ? $0.ingredients : nil },
      servingsConsumed: servings,
      portionMultiplier: portionMultiplier
    )
  }

  var body: some View {
    FLCard {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        HStack {
          Text("Ingredient Breakdown")
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          if case .ingredients(let rows) = content {
            Text("\(rows.count) item\(rows.count == 1 ? "" : "s")")
              .font(AppTheme.Typography.labelSmall)
              .foregroundStyle(AppTheme.textSecondary)
              .contentTransition(.numericText())
          }
        }

        if let message = content.message {
          Text(message)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.textSecondary)
        }

        if case .ingredients(let rows) = content {
          VStack(spacing: AppTheme.Space.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
              ingredientRow(row)
              if index < rows.count - 1 {
                Divider()
              }
            }
          }
        }
      }
    }
    .task(id: catalogId ?? recipe?.id.map { String($0) }) {
      await loadIngredients()
    }
  }

  private func loadIngredients() async {
    if let catalogId {
      // Unscreened by design: the household already chose this recipe in the screened picker
      // or match list, and the breakdown offers nothing new.
      let packet = try? deps.recipeRepository.unscreenedCatalog.cookPacket(catalogId: catalogId)
      withAnimation(reduceMotion ? nil : AppMotion.gentle) {
        loadedCatalog = (catalogId, packet)
      }
      return
    }
    guard let recipeID = recipe?.id else { return }
    let ingredients = (try? deps.recipeRepository.ingredientsForRecipe(id: recipeID)) ?? []
    withAnimation(reduceMotion ? nil : AppMotion.gentle) {
      loaded = (recipeID, ingredients)
    }
  }

  private func ingredientRow(_ row: MealBreakdownRow) -> some View {
    HStack(spacing: AppTheme.Space.sm) {
      Text(row.name)
        .font(AppTheme.Typography.bodyMedium)
        .foregroundStyle(AppTheme.textPrimary)
        .lineLimit(1)

      Spacer()

      Text(prefs.formatWeight(grams: row.grams))
        .font(AppTheme.Typography.dataSmall)
        .foregroundStyle(AppTheme.textPrimary)
        .contentTransition(.numericText())
    }
    .padding(.vertical, AppTheme.Space.xxxs)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Log Submission

/// Whether Log a Meal may write the meal now. A photo logs once: after a successful log the
/// button stays off until a new photo is analyzed. A failed log can be retried.
struct MealLogSubmission: Equatable {
  enum Phase: Equatable {
    case ready
    case logging
    case logged
  }

  private(set) var phase: Phase = .ready

  var canSubmit: Bool { phase == .ready }

  /// Starts a log. Returns false, and changes nothing, unless the screen is ready.
  mutating func begin() -> Bool {
    guard canSubmit else { return false }
    phase = .logging
    return true
  }

  mutating func finish(succeeded: Bool) {
    guard phase == .logging else { return }
    phase = succeeded ? .logged : .ready
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
