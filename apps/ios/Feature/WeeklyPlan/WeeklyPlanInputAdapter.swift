import Foundation
import FLFeatureLogic

/// Adapts read-only app state into `WeeklyPlanInput` for the planner.
///
/// The planner core is deliberately repository-free; this is the seam. The
/// adapter is pure mapping over the values it is handed — it performs no
/// queries, reserves no stock, and computes no new policy. Every policy
/// decision below is a documented projection of existing app state:
///
/// - **Stock:** one `WeeklyPlanStockItem` per remaining lot (`fetchPlanningLots`),
///   `quantityIsKnown = !quantityIsEstimate`. Duplicate ingredient IDs collapse
///   in `WeeklyPlanInput.stockByID`: known lots sum, any unconfirmed lot taints
///   the whole ingredient.
/// - **Urgencies:** derived from the earliest expiry per ingredient. A lot
///   expiring within `useSoonWindowDays` days gives its ingredient a use-soon
///   weight of `(window − daysRemaining) / window` points per gram (1.0 at the
///   expiry day, clamped for already-expired lots). Nothing outside the window
///   contributes. The planner only multiplies and sums these.
/// - **Hard exclusions:** `HealthProfile.effectiveAllergenExclusionIds`
///   (explicit groups ∪ individual exclusions) ∪ `dietaryExcludedIngredientIds`.
///   Exclusions are hard — the planner can never waive them.
/// - **Diet:** `HealthProfile.selectedDietID` becomes `requiredDietClass`.
/// - **Recipe diet class:** the recipe's own tags — `.vegan` → "vegan",
///   `.vegetarian` → "vegetarian", `.lowCarb` → "keto", else nil. This mirrors
///   `HealthProfile.requiredRecipeTagMask`'s mapping in reverse.
/// - **Needs:** `RecipeIngredient` per serving, `isOptional = !isRequired`.
///   The schema stores no substitutes, so `substitutes` stays empty.
enum WeeklyPlanInputAdapter {
  /// Use-soon window: lots expiring within this many days carry urgency.
  static let useSoonWindowDays = 3

  /// The default week: three dinner slots, inside the planner's
  /// guaranteed-optimal domain (≤ 6 recipes × ≤ 3 slots).
  static func defaultSlots() -> [WeeklyPlanSlot] {
    [
      WeeklyPlanSlot(id: 1, label: "Monday dinner"),
      WeeklyPlanSlot(id: 2, label: "Tuesday dinner"),
      WeeklyPlanSlot(id: 3, label: "Wednesday dinner"),
    ]
  }

  /// The recipe's own diet class, used for eligibility when the profile
  /// requires one. Unrestricted recipes stay nil.
  static func dietClass(for recipe: Recipe) -> String? {
    let tags = recipe.recipeTags
    if tags.contains(.vegan) { return "vegan" }
    if tags.contains(.vegetarian) { return "vegetarian" }
    if tags.contains(.lowCarb) { return "keto" }
    return nil
  }

  /// Builds the complete planning input. `ingredientsByRecipe` is keyed by the
  /// same recipe IDs as `recipes`; recipes without a persisted ID are skipped.
  static func makeInput(
    recipes: [Recipe],
    ingredientsByRecipe: [Int64: [(ingredient: Ingredient, quantity: RecipeIngredient)]],
    lots: [InventoryPlanningLot],
    profile: HealthProfile,
    servingsPerMeal: Int = 2,
    maxCookTimeMinutes: Int? = nil,
    maxRepeatsPerRecipe: Int = 1,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> WeeklyPlanInput {
    let plannedRecipes: [WeeklyPlanRecipe] = recipes.compactMap { recipe in
      guard let recipeId = recipe.id,
        let rows = ingredientsByRecipe[recipeId]
      else { return nil }
      let needs = rows.map {
        WeeklyPlanNeed(
          ingredientId: $0.quantity.ingredientId,
          gramsPerServing: max(0, $0.quantity.quantityGrams),
          isOptional: !$0.quantity.isRequired)
      }
      return WeeklyPlanRecipe(
        id: recipeId, title: recipe.title, timeMinutes: recipe.timeMinutes,
        dietClass: dietClass(for: recipe), needs: needs)
    }

    let stock = lots.filter { $0.remainingGrams > 0 }.map {
      WeeklyPlanStockItem(
        ingredientId: $0.ingredientId, availableGrams: $0.remainingGrams,
        quantityIsKnown: !$0.quantityIsEstimate)
    }

    return WeeklyPlanInput(
      slots: defaultSlots(),
      recipes: plannedRecipes,
      stock: stock,
      urgencies: urgencies(lots: lots, now: now, calendar: calendar),
      constraints: WeeklyPlanConstraints(
        excludedIngredientIds: profile.effectiveAllergenExclusionIds
          .union(profile.dietaryExcludedIngredientIds),
        requiredDietClass: profile.selectedDietID,
        maxCookTimeMinutes: maxCookTimeMinutes,
        servingsPerMeal: servingsPerMeal,
        maxRepeatsPerRecipe: maxRepeatsPerRecipe))
  }

  /// Use-soon urgency per ingredient, from the earliest expiring remaining lot.
  /// Weight 1.0/gram at the expiry day, decaying linearly to 0 at the window
  /// edge; already-expired lots count as expiry day. Absent = no urgency.
  static func urgencies(
    lots: [InventoryPlanningLot], now: Date = Date(), calendar: Calendar = .current
  ) -> [WeeklyPlanUrgency] {
    let today = calendar.startOfDay(for: now)
    let earliestByIngredient = Dictionary(
      lots.filter { $0.expiresAt != nil && $0.remainingGrams > 0 }.map {
        ($0.ingredientId, calendar.startOfDay(for: $0.expiresAt!))
      },
      uniquingKeysWith: min
    )

    return earliestByIngredient.compactMap { ingredientId, expiryDay in
      let daysRemaining = calendar.dateComponents([.day], from: today, to: expiryDay).day ?? 0
      guard daysRemaining < useSoonWindowDays else { return nil }
      let clampedDays = max(0, daysRemaining)
      let weight = Double(useSoonWindowDays - clampedDays) / Double(useSoonWindowDays)
      return weight > 0 ? WeeklyPlanUrgency(ingredientId: ingredientId, weightPerGram: weight) : nil
    }
  }
}
