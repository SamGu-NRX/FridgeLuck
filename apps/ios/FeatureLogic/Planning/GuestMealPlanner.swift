import Foundation

/// Builds a shopping list for a menu where each guest gets one serving of every recipe.
/// Quantities are grams in the same ingredient form as the recipe, without unit conversion.
public enum GuestMealPlanner {
  public struct IngredientAmount: Sendable, Equatable {
    public let ingredientID: Int64
    public let grams: Double

    public init(ingredientID: Int64, grams: Double) {
      self.ingredientID = ingredientID
      self.grams = grams
    }
  }

  public struct Recipe: Sendable {
    /// Any nonzero ID. Catalog recipes use negative IDs (`PlanDataAdapter.catalogDatabaseID`)
    /// so they never collide with positive legacy `recipes.id` values.
    public let recipeID: Int64
    public let baseServings: Int
    /// Includes the ingredients the user intends to prepare, including chosen optional ingredients.
    public let ingredients: [IngredientAmount]

    public init(recipeID: Int64, baseServings: Int, ingredients: [IngredientAmount]) {
      self.recipeID = recipeID
      self.baseServings = baseServings
      self.ingredients = ingredients
    }
  }

  public enum QuantityStatus: Sendable {
    case confirmed
    case needsConfirmation
  }

  public struct InventoryLot: Sendable {
    public let lotID: Int64
    public let ingredientID: Int64
    public let remainingGrams: Double
    public let quantityStatus: QuantityStatus
    /// A planning cutoff supplied by the inventory source, not a food-safety determination.
    public let expiresAt: Date?

    public init(
      lotID: Int64,
      ingredientID: Int64,
      remainingGrams: Double,
      quantityStatus: QuantityStatus,
      expiresAt: Date? = nil
    ) {
      self.lotID = lotID
      self.ingredientID = ingredientID
      self.remainingGrams = remainingGrams
      self.quantityStatus = quantityStatus
      self.expiresAt = expiresAt
    }
  }

  public struct GroceryLine: Sendable, Equatable {
    public let ingredientID: Int64
    public let requiredGrams: Double
    public let availableGrams: Double
    public let allocatedGrams: Double
    public let missingGrams: Double
    public let needsConfirmationGrams: Double
    public let expiresBeforeEventGrams: Double
  }

  public struct Plan: Sendable, Equatable {
    public let guestCount: Int
    public let eventDate: Date
    /// Sorted by ingredient ID, including fully stocked ingredients for review.
    public let ingredients: [GroceryLine]

    public var shoppingList: [GroceryLine] {
      ingredients.filter { $0.missingGrams > 0 }
    }
  }

  public enum PlanningError: Error, Equatable {
    case invalidGuestCount
    case invalidEventDate
    case emptyMenu
    case invalidRecipe(Int64)
    case duplicateRecipe(Int64)
    case invalidBaseServings(Int64)
    case emptyRecipe(Int64)
    case invalidIngredient(Int64)
    case invalidRecipeGrams(recipeID: Int64, ingredientID: Int64)
    case invalidLot(Int64)
    case duplicateLot(Int64)
    case invalidInventoryGrams(Int64)
    case invalidExpiry(Int64)
    case quantityOverflow(Int64)
  }

  /// Recomputes from a snapshot. Stock is shared across the whole menu, never deducted or reserved.
  /// Unconfirmed quantities and lots expiring at or before the event do not reduce the shopping list.
  /// A nil expiry means no recorded cutoff; it does not certify freshness.
  public static func plan(
    guestCount: Int,
    eventDate: Date,
    recipes: [Recipe],
    inventory: [InventoryLot]
  ) throws -> Plan {
    guard guestCount > 0 else { throw PlanningError.invalidGuestCount }
    guard eventDate.timeIntervalSinceReferenceDate.isFinite else {
      throw PlanningError.invalidEventDate
    }
    guard !recipes.isEmpty else { throw PlanningError.emptyMenu }

    var required: [Int64: Double] = [:]
    var recipeIDs = Set<Int64>()
    for recipe in recipes {
      guard recipe.recipeID != 0 else { throw PlanningError.invalidRecipe(recipe.recipeID) }
      guard recipeIDs.insert(recipe.recipeID).inserted else {
        throw PlanningError.duplicateRecipe(recipe.recipeID)
      }
      guard recipe.baseServings > 0 else {
        throw PlanningError.invalidBaseServings(recipe.recipeID)
      }
      guard !recipe.ingredients.isEmpty else { throw PlanningError.emptyRecipe(recipe.recipeID) }
      let scale = Double(guestCount) / Double(recipe.baseServings)
      for ingredient in recipe.ingredients {
        guard ingredient.ingredientID > 0 else {
          throw PlanningError.invalidIngredient(ingredient.ingredientID)
        }
        guard ingredient.grams.isFinite, ingredient.grams > 0 else {
          throw PlanningError.invalidRecipeGrams(
            recipeID: recipe.recipeID, ingredientID: ingredient.ingredientID
          )
        }
        try add(ingredient.grams * scale, to: &required, ingredientID: ingredient.ingredientID)
      }
    }

    var available: [Int64: Double] = [:]
    var needsConfirmation: [Int64: Double] = [:]
    var expiresBeforeEvent: [Int64: Double] = [:]
    var lotIDs = Set<Int64>()
    for lot in inventory {
      guard lot.lotID > 0 else { throw PlanningError.invalidLot(lot.lotID) }
      guard lotIDs.insert(lot.lotID).inserted else { throw PlanningError.duplicateLot(lot.lotID) }
      guard lot.ingredientID > 0 else { throw PlanningError.invalidIngredient(lot.ingredientID) }
      guard lot.remainingGrams.isFinite, lot.remainingGrams >= 0 else {
        throw PlanningError.invalidInventoryGrams(lot.lotID)
      }
      if let expiry = lot.expiresAt, !expiry.timeIntervalSinceReferenceDate.isFinite {
        throw PlanningError.invalidExpiry(lot.lotID)
      }
      guard required[lot.ingredientID] != nil else { continue }
      // Expiry takes precedence so the same lot is never counted in both exclusion totals.
      if let expiry = lot.expiresAt, expiry <= eventDate {
        try add(lot.remainingGrams, to: &expiresBeforeEvent, ingredientID: lot.ingredientID)
      } else {
        switch lot.quantityStatus {
        case .confirmed:
          try add(lot.remainingGrams, to: &available, ingredientID: lot.ingredientID)
        case .needsConfirmation:
          try add(lot.remainingGrams, to: &needsConfirmation, ingredientID: lot.ingredientID)
        }
      }
    }

    let lines = required.keys.sorted().map { ingredientID in
      let demand = required[ingredientID, default: 0]
      let stock = available[ingredientID, default: 0]
      let allocated = min(demand, stock)
      return GroceryLine(
        ingredientID: ingredientID,
        requiredGrams: demand,
        availableGrams: stock,
        allocatedGrams: allocated,
        missingGrams: demand - allocated,
        needsConfirmationGrams: needsConfirmation[ingredientID, default: 0],
        expiresBeforeEventGrams: expiresBeforeEvent[ingredientID, default: 0]
      )
    }
    return Plan(guestCount: guestCount, eventDate: eventDate, ingredients: lines)
  }

  private static func add(
    _ grams: Double, to quantities: inout [Int64: Double], ingredientID: Int64
  ) throws {
    let total = quantities[ingredientID, default: 0] + grams
    guard grams.isFinite, total.isFinite else { throw PlanningError.quantityOverflow(ingredientID) }
    quantities[ingredientID] = total
  }
}
