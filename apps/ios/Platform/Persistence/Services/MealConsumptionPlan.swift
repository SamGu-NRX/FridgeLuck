import Foundation
import GRDB

// MARK: - Plan building blocks

/// Where a plan line's quantity came from. The suggested recipe amount is the app's own
/// estimate from the recipe; a user-verified amount is the user's correction of it. Kept
/// per line, so a plan where some lines were corrected and others were not stays honest
/// about which numbers the user actually saw and accepted.
enum MealQuantityProvenance: String, Sendable, Codable, Hashable {
  case suggestedRecipeQuantity
  case userVerified
}

/// Nutrition per 100 g, captured when the plan is built so edits and later corrections
/// reason over the numbers the user saw. Catalog edits do not rewrite a plan in flight.
struct MealNutritionPer100g: Sendable, Equatable, Codable, Hashable {
  var calories: Double
  var protein: Double
  var carbs: Double
  var fat: Double
  var fiber: Double
  var sugar: Double
  /// Grams of sodium per 100 g, matching the ingredients table's unit.
  var sodium: Double

  static let zero = MealNutritionPer100g(
    calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0, sodium: 0)
}

// MARK: - Plan lines

/// One ingredient of a meal plan: what the recipe asks for, what the user accepts, and
/// where that number came from.
struct MealConsumptionPlanLine: Sendable, Equatable, Codable, Hashable {
  /// The ingredient the Kitchen sees: the recipe's own ingredient, or the substitute a
  /// swap resolved to. Rebuilds re-resolve it, so a line that changes ingredient re-ids.
  var resolvedIngredientId: Int64
  /// The recipe's own ingredient when a swap replaced it, nil otherwise.
  var originalIngredientId: Int64?
  var displayName: String
  /// The recipe's grams for this line (post-swap), before servings and portion scaling.
  var recipeReferenceGrams: Double
  /// What this plan proposes to deduct for the meal. Fractional grams, never below zero.
  var plannedGrams: Double
  var provenance: MealQuantityProvenance
  var nutritionPer100g: MealNutritionPer100g
  /// What logging actually took out for this line (capped at stock). Zero while the plan
  /// is only proposed; filled at acceptance and kept by corrections.
  var appliedGrams: Double

  /// Stable across rebuilds: the recipe's own ingredient when there is one, otherwise the
  /// resolved one. Corrections and rebuilds match accepted lines by this key.
  var lineKey: Int64 { originalIngredientId ?? resolvedIngredientId }

  /// This line's nutrition contribution given its planned grams.
  func scaledMacros() -> MealNutritionPer100g {
    let factor = max(0, plannedGrams) / 100.0
    return MealNutritionPer100g(
      calories: nutritionPer100g.calories * factor,
      protein: nutritionPer100g.protein * factor,
      carbs: nutritionPer100g.carbs * factor,
      fat: nutritionPer100g.fat * factor,
      fiber: nutritionPer100g.fiber * factor,
      sugar: nutritionPer100g.sugar * factor,
      sodium: nutritionPer100g.sodium * factor
    )
  }
}

// MARK: - Plan

/// The one object a meal's display, deduction preview and accepted logging all read: what
/// the recipe asks for, what the user verified, and what logging did about it.
///
/// Accepted plans are persisted on the cooking_history row (JSON) and are deduplicated by
/// `identity`, so a retried log of the same plan cannot deduct from the Kitchen twice.
struct MealConsumptionPlan: Sendable, Equatable, Codable, Hashable {
  /// Stable across rebuilds of the same in-flight plan.
  var identity: String
  var recipeId: Int64
  var recipeTitle: String
  var recipeServings: Int
  var servingsConsumed: Int
  var portionMultiplier: Double
  var lines: [MealConsumptionPlanLine]
  /// The local day the accepted log counted toward in streaks; set at acceptance.
  var acceptedStreakDay: String?

  /// Total nutrition the plan proposes to consume across its lines.
  var totalMacros: MealNutritionPer100g {
    lines.reduce(MealNutritionPer100g.zero) { partial, line in
      let scaled = line.scaledMacros()
      return MealNutritionPer100g(
        calories: partial.calories + scaled.calories,
        protein: partial.protein + scaled.protein,
        carbs: partial.carbs + scaled.carbs,
        fat: partial.fat + scaled.fat,
        fiber: partial.fiber + scaled.fiber,
        sugar: partial.sugar + scaled.sugar,
        sodium: partial.sodium + scaled.sodium
      )
    }
  }

  /// What logging this plan takes out of the Kitchen, grouped per resolved ingredient in
  /// first-seen line order. Requested grams are the plan's proposals; consumed grams are
  /// the accepted, stock-capped amounts (zero while the plan is only proposed).
  func aggregatedConsumption() -> [InventoryConsumptionResult] {
    var order: [Int64] = []
    var byIngredient: [Int64: (requested: Double, consumed: Double)] = [:]
    for line in lines {
      let requested = max(0, line.plannedGrams)
      if byIngredient[line.resolvedIngredientId] == nil {
        order.append(line.resolvedIngredientId)
      }
      let tally = byIngredient[line.resolvedIngredientId] ?? (0, 0)
      byIngredient[line.resolvedIngredientId] = (
        tally.requested + requested,
        tally.consumed + max(0, line.appliedGrams)
      )
    }
    return order.map { ingredientId in
      let tally = byIngredient[ingredientId] ?? (0, 0)
      return InventoryConsumptionResult(
        ingredientId: ingredientId,
        requestedGrams: tally.requested,
        consumedGrams: tally.consumed,
        shortfallGrams: max(0, tally.requested - tally.consumed)
      )
    }
  }

  /// Rebuilds the plan for new servings or portion without touching the catalog: suggested
  /// lines scale with the recipe's factor, user-verified lines keep their absolute grams,
  /// and the identity survives. A changed recipe rebuilds from the catalog instead — the
  /// builder is the only place that re-reads ingredient rows.
  func rescaled(servingsConsumed: Int, portionMultiplier: Double) -> MealConsumptionPlan {
    let safeServings = max(1, servingsConsumed)
    let factor = InventoryRepository.servingFactor(
      servingsConsumed: safeServings,
      portionMultiplier: portionMultiplier,
      recipeServings: max(recipeServings, 1)
    )
    var plan = self
    plan.servingsConsumed = safeServings
    plan.portionMultiplier = portionMultiplier
    plan.lines = lines.map { line in
      var line = line
      if line.provenance == .suggestedRecipeQuantity {
        line.plannedGrams = max(0, line.recipeReferenceGrams * factor)
      }
      return line
    }
    return plan
  }

  /// The same plan with acceptance evidence cleared, used defensively before a fresh log.
  func resetApplied() -> MealConsumptionPlan {
    var plan = self
    plan.lines = lines.map { line in
      var line = line
      line.appliedGrams = 0
      return line
    }
    return plan
  }

  // MARK: Persistence

  /// JSON for cooking_history.accepted_plan_json, or nil when the plan cannot be encoded.
  var persistedJSONString: String? {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Decodes a persisted plan; nil when the JSON is missing or unreadable, which leaves
  /// the log correct-but-not-correctable rather than crashing the journal.
  static func decode(from json: String?) -> MealConsumptionPlan? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(MealConsumptionPlan.self, from: data)
  }
}

// MARK: - Errors

enum MealConsumptionPlanError: LocalizedError {
  case unknownRecipe(Int64)
  case unknownSubstituteIngredient(Int64)
  case planRecipeMismatch(planRecipeId: Int64, resolvedRecipeId: Int64)
  case invalidPlannedGrams(Double)

  var errorDescription: String? {
    switch self {
    case .unknownRecipe(let recipeId):
      return "Recipe \(recipeId) is not in the catalog anymore."
    case .unknownSubstituteIngredient(let ingredientId):
      return "Swapped-in ingredient \(ingredientId) is not in the catalog anymore."
    case .planRecipeMismatch(let planRecipeId, let resolvedRecipeId):
      return "The plan belongs to recipe \(planRecipeId), but the meal resolves to recipe \(resolvedRecipeId)."
    case .invalidPlannedGrams(let grams):
      return "Planned quantity \(grams) g is not a usable amount."
    }
  }
}

// MARK: - Builder

/// Builds a meal consumption plan from real recipe and ingredient rows. Stateless: every
/// call re-reads the catalog, applies the session's swaps, and carries user-verified grams
/// from a previous build of the same plan so edits survive rebuilds.
enum MealConsumptionPlanBuilder {
  /// Builds inside an existing transaction.
  static func build(
    in db: Database,
    recipeId: Int64,
    servingsConsumed: Int,
    portionMultiplier: Double,
    swaps: [IngredientSwap] = [],
    previous: MealConsumptionPlan? = nil
  ) throws -> MealConsumptionPlan {
    guard let recipe = try Recipe.fetchOne(db, key: recipeId) else {
      throw MealConsumptionPlanError.unknownRecipe(recipeId)
    }
    let safeServings = max(1, servingsConsumed)
    let safePortion = portionMultiplier.isFinite && portionMultiplier > 0 ? portionMultiplier : 1.0
    let factor = InventoryRepository.servingFactor(
      servingsConsumed: safeServings,
      portionMultiplier: safePortion,
      recipeServings: max(recipe.servings, 1)
    )

    let swapByOriginal = Dictionary(
      swaps.map { ($0.originalIngredientId, $0) }, uniquingKeysWith: { _, last in last })
    let substituteNutritionById = try substituteNutrition(
      in: db, swaps: swaps)

    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT ri.ingredient_id, ri.quantity_grams,
          i.name AS ingredient_name,
          i.calories, i.protein, i.carbs, i.fat, i.fiber, i.sugar, i.sodium
        FROM recipe_ingredients ri
        JOIN ingredients i ON i.id = ri.ingredient_id
        WHERE ri.recipe_id = ? AND ri.is_required = 1
        ORDER BY ri.ingredient_id
        """,
      arguments: [recipeId]
    )

    let previousByKey = Dictionary(
      previous.map { $0.lines.map { ($0.lineKey, $0) } } ?? [],
      uniquingKeysWith: { _, last in last }
    )
    // A rebuild of the same recipe keeps the plan's identity so acceptance deduplication
    // still recognizes it; a different recipe starts a fresh plan.
    let identity =
      (previous?.recipeId == recipeId ? previous?.identity : nil) ?? UUID().uuidString

    let lines = rows.map { row -> MealConsumptionPlanLine in
      let originalId: Int64 = row["ingredient_id"]
      let baseGrams: Double = row["quantity_grams"]
      let swap = swapByOriginal[originalId]
      let resolvedId = swap?.substituteIngredientId ?? originalId
      let referenceGrams = max(0, baseGrams * (swap?.ratio ?? 1.0))

      let nutrition: MealNutritionPer100g
      let displayName: String
      if swap != nil, let substitute = substituteNutritionById[resolvedId] {
        nutrition = substitute.nutrition
        displayName = substitute.displayName
      } else {
        let name: String = row["ingredient_name"]
        nutrition = MealNutritionPer100g(
          calories: row["calories"] as Double? ?? 0,
          protein: row["protein"] as Double? ?? 0,
          carbs: row["carbs"] as Double? ?? 0,
          fat: row["fat"] as Double? ?? 0,
          fiber: row["fiber"] as Double? ?? 0,
          sugar: row["sugar"] as Double? ?? 0,
          sodium: row["sodium"] as Double? ?? 0
        )
        displayName = name.replacingOccurrences(of: "_", with: " ").localizedCapitalized
      }

      let previousLine = previousByKey[originalId]
      let provenance = previousLine?.provenance ?? .suggestedRecipeQuantity
      let plannedGrams: Double
      if previousLine?.provenance == .userVerified {
        // The user set this line's absolute grams; rescaling the recipe around them
        // would silently discard what they corrected.
        plannedGrams = max(0, previousLine?.plannedGrams ?? 0)
      } else {
        plannedGrams = max(0, referenceGrams * factor)
      }

      return MealConsumptionPlanLine(
        resolvedIngredientId: resolvedId,
        originalIngredientId: swap != nil ? originalId : nil,
        displayName: displayName,
        recipeReferenceGrams: referenceGrams,
        plannedGrams: plannedGrams,
        provenance: provenance,
        nutritionPer100g: nutrition,
        appliedGrams: 0
      )
    }

    return MealConsumptionPlan(
      identity: identity,
      recipeId: recipeId,
      recipeTitle: recipe.title,
      recipeServings: max(recipe.servings, 1),
      servingsConsumed: safeServings,
      portionMultiplier: safePortion,
      lines: lines,
      acceptedStreakDay: nil
    )
  }

  /// Builds on a queue outside a transaction, for view-side builds.
  static func build(
    from reader: some DatabaseReader,
    recipeId: Int64,
    servingsConsumed: Int,
    portionMultiplier: Double,
    swaps: [IngredientSwap] = [],
    previous: MealConsumptionPlan? = nil
  ) throws -> MealConsumptionPlan {
    try reader.read { db in
      try build(
        in: db,
        recipeId: recipeId,
        servingsConsumed: servingsConsumed,
        portionMultiplier: portionMultiplier,
        swaps: swaps,
        previous: previous
      )
    }
  }

  private struct SubstituteNutrition {
    var displayName: String
    var nutrition: MealNutritionPer100g
  }

  private static func substituteNutrition(
    in db: Database, swaps: [IngredientSwap]
  ) throws -> [Int64: SubstituteNutrition] {
    let substituteIds = Set(swaps.map(\.substituteIngredientId))
    guard !substituteIds.isEmpty else { return [:] }
    let placeholders = substituteIds.map { _ in "?" }.joined(separator: ", ")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, name, calories, protein, carbs, fat, fiber, sugar, sodium
        FROM ingredients WHERE id IN (\(placeholders))
        """,
      arguments: StatementArguments(substituteIds)
    )
    var byId: [Int64: SubstituteNutrition] = [:]
    for row in rows {
      let id: Int64 = row["id"]
      let name: String = row["name"]
      byId[id] = SubstituteNutrition(
        displayName: name.replacingOccurrences(of: "_", with: " ").localizedCapitalized,
        nutrition: MealNutritionPer100g(
          calories: row["calories"] as Double? ?? 0,
          protein: row["protein"] as Double? ?? 0,
          carbs: row["carbs"] as Double? ?? 0,
          fat: row["fat"] as Double? ?? 0,
          fiber: row["fiber"] as Double? ?? 0,
          sugar: row["sugar"] as Double? ?? 0,
          sodium: row["sodium"] as Double? ?? 0
        )
      )
    }
    for swap in swaps where byId[swap.substituteIngredientId] == nil {
      throw MealConsumptionPlanError.unknownSubstituteIngredient(swap.substituteIngredientId)
    }
    return byId
  }
}

// MARK: - Preview models

/// Read-only consequence of one plan line against the current Kitchen, in plan order.
/// The deduction preview and the accepted deduction walk the lines the same way, so the
/// preview is what logging does — including when two lines resolve to one ingredient.
struct MealPlanLinePreview: Sendable, Equatable {
  var lineKey: Int64
  var resolvedIngredientId: Int64
  var ingredientName: String
  var plannedGrams: Double
  /// Kitchen stock at this line's turn, after earlier lines claimed their share.
  var availableGrams: Double
  var deductedGrams: Double
  var shortfallGrams: Double
}

extension MealPlanLinePreview {
  /// Folds per-line previews into one preview per resolved ingredient, matching what an
  /// accepted log records in `inventoryConsumption`.
  static func ingredientPreviews(from linePreviews: [MealPlanLinePreview])
    -> [InventoryDeductionPreview]
  {
    var order: [Int64] = []
    var byIngredient: [Int64: (name: String, proposed: Double, deducted: Double, available: Double)] = [:]
    for preview in linePreviews {
      if byIngredient[preview.resolvedIngredientId] == nil {
        order.append(preview.resolvedIngredientId)
      }
      let tally = byIngredient[preview.resolvedIngredientId]
      byIngredient[preview.resolvedIngredientId] = (
        preview.ingredientName,
        (tally?.proposed ?? 0) + preview.plannedGrams,
        (tally?.deducted ?? 0) + preview.deductedGrams,
        tally?.available ?? preview.availableGrams
      )
    }
    return order.compactMap { ingredientId in
      guard let tally = byIngredient[ingredientId] else { return nil }
      return InventoryDeductionPreview(
        ingredientId: ingredientId,
        ingredientName: tally.name,
        proposedGrams: tally.proposed,
        availableGrams: tally.available,
        deductedGrams: tally.deducted,
        shortfallGrams: max(0, tally.proposed - tally.available)
      )
    }
  }
}
