import FLFeatureLogic
import Foundation
import GRDB

struct GuestMealRecipe: Identifiable, Sendable {
  let recipe: Recipe
  let ingredients: [RecipeIngredient]
  var id: Int64? { recipe.id }
}

struct GuestMealSnapshot: Sendable {
  let recipes: [GuestMealRecipe]
  let lots: [InventoryLot]
  let ingredientNames: [Int64: String]

  static func load(from queue: DatabaseQueue) async throws -> Self {
    try await queue.read { db in
      let recipes = try Recipe.order(Recipe.Columns.title).fetchAll(db)
      let rows = try RecipeIngredient.fetchAll(db)
      let grouped = Dictionary(grouping: rows, by: \.recipeId)
      let ingredients = try Ingredient.fetchAll(db, sql: """
        SELECT * FROM ingredients WHERE id IN (
          SELECT ingredient_id FROM recipe_ingredients
        )
        """)
      let lots = try InventoryLot.fetchAll(db, sql: """
        SELECT * FROM inventory_lots WHERE remaining_grams != 0 AND ingredient_id IN (
          SELECT ingredient_id FROM recipe_ingredients
        ) ORDER BY acquired_at, id
        """)
      return Self(
        recipes: recipes.map { GuestMealRecipe(recipe: $0, ingredients: grouped[$0.id ?? 0] ?? []) },
        lots: lots,
        ingredientNames: Dictionary(uniqueKeysWithValues: ingredients.compactMap {
          guard let id = $0.id else { return nil }
          return (id, $0.displayName)
        })
      )
    }
  }
}

enum GuestMealMapping {
  struct Issue: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
  }

  static func recipe(_ stored: GuestMealRecipe, optionalIDs: Set<Int64>) throws -> GuestMealPlanner.Recipe {
    let title = stored.recipe.title
    guard let id = stored.id, id > 0 else {
      throw Issue(message: "\(title) has no saved recipe ID. Choose another recipe.")
    }
    guard stored.recipe.servings > 0 else {
      throw Issue(message: "\(title) needs a valid serving count. Choose another recipe until it is corrected.")
    }
    let rows = stored.ingredients.filter { $0.isRequired || optionalIDs.contains($0.ingredientId) }
    guard !rows.isEmpty else {
      throw Issue(message: "\(title) has no selected ingredients. Include an optional ingredient or choose another recipe.")
    }
    var seen = Set<Int64>()
    for row in rows {
      guard row.recipeId == id, row.ingredientId > 0,
        seen.insert(row.ingredientId).inserted,
        row.quantityGrams.isFinite, row.quantityGrams > 0
      else {
        throw Issue(message: "\(title) has invalid ingredient quantities. Choose another recipe until it is corrected.")
      }
    }
    return .init(recipeID: id, baseServings: stored.recipe.servings, ingredients: rows.map {
      .init(ingredientID: $0.ingredientId, grams: $0.quantityGrams)
    })
  }

  static func lot(
    _ stored: InventoryLot, reviewedGrams: Double?, name: String
  ) throws -> GuestMealPlanner.InventoryLot {
    guard let id = stored.id, id > 0 else {
      throw Issue(message: "\(name) has a stock lot without a saved ID. Correct it in your fridge, then reload inventory.")
    }
    let grams = reviewedGrams ?? stored.remainingGrams
    guard stored.ingredientId > 0, grams.isFinite, grams >= 0 else {
      throw Issue(message: "\(name), lot \(id), needs a valid amount in grams. Review its stock below.")
    }
    if let expiry = stored.expiresAt, !expiry.timeIntervalSinceReferenceDate.isFinite {
      throw Issue(message: "\(name), lot \(id), has an invalid expiry. Correct it in your fridge, then reload inventory.")
    }
    // Confidence describes recognition, not a host's review of grams or ingredient form.
    return .init(
      lotID: id, ingredientID: stored.ingredientId, remainingGrams: grams,
      quantityStatus: reviewedGrams == nil ? .needsConfirmation : .confirmed,
      expiresAt: stored.expiresAt
    )
  }
}
