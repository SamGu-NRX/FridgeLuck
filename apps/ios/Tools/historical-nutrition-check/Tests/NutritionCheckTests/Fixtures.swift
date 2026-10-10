import Foundation
import GRDB
import XCTest

@testable import NutritionCheck

/// Shared fixtures: a fresh per-test database migrated to a chosen version,
/// plus a small catalog and meal set seeded with the pre-snapshot (v18)
/// schema, mirroring how an existing install's data looks before the v20
/// upgrade.
enum Fixtures {
  // Migration keys.
  static let v18 = "v18_cooking_history_swaps"

  struct IngredientSpec {
    let id: Int64
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let fiber: Double
    let sugar: Double
    let sodium: Double
  }

  struct LineSpec {
    let ingredientId: Int64
    let grams: Double
    let required: Bool
  }

  struct RecipeSpec {
    let id: Int64
    let servings: Int
    let lines: [LineSpec]
  }

  struct SwapSpec {
    let originalId: Int64
    let substituteId: Int64
    let ratio: Double
  }

  struct MealSpec {
    let id: Int64
    let recipeId: Int64
    let cookedAt: String?
    let servingsConsumed: Int?
    let portion: Double
    let swaps: [SwapSpec]
  }

  // Fractional per-100g values so bit-level comparisons detect any rounding
  // shortcut in capture or backfill.
  static let ingredients: [IngredientSpec] = [
    .init(id: 1, calories: 52.17, protein: 0.83, carbs: 11.31, fat: 0.37, fiber: 1.7, sugar: 2.13, sodium: 4.0),
    .init(id: 2, calories: 89.21, protein: 1.09, carbs: 22.84, fat: 0.33, fiber: 2.6, sugar: 12.23, sodium: 1.0),
    .init(id: 3, calories: 248.63, protein: 4.51, carbs: 0.11, fat: 24.77, fiber: 0.0, sugar: 0.49, sodium: 7.0),
  ]

  // R1 exercises fractional grams and a substitute swap (ingredient 3 -> 2).
  // R2 is the empty recipe. R3 is the doomed recipe (orphan case).
  static let recipes: [RecipeSpec] = [
    .init(id: 1, servings: 2, lines: [
      .init(ingredientId: 1, grams: 150.0, required: true),
      .init(ingredientId: 2, grams: 33.75, required: true),
      .init(ingredientId: 3, grams: 30.5, required: true),
    ]),
    .init(id: 2, servings: 4, lines: []),
    .init(id: 3, servings: 1, lines: [
      .init(ingredientId: 1, grams: 100.0, required: true),
    ]),
  ]

  static let meals: [MealSpec] = [
    .init(id: 1, recipeId: 1, cookedAt: "2026-10-01 08:30:00.000", servingsConsumed: 1, portion: 1.0, swaps: [
      .init(originalId: 3, substituteId: 2, ratio: 0.333333),
    ]),
    .init(id: 2, recipeId: 1, cookedAt: "2026-10-01 12:00:00.000", servingsConsumed: nil, portion: 0.75, swaps: []),
    .init(id: 3, recipeId: 1, cookedAt: nil, servingsConsumed: nil, portion: 1.0, swaps: []),
    .init(id: 4, recipeId: 3, cookedAt: "2026-10-01 19:00:00.000", servingsConsumed: 1, portion: 1.0, swaps: []),
  ]

  static func makeQueue(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> DatabaseQueue {
    let path = NSTemporaryDirectory() + "hnc-\(name)-\(UUID().uuidString).sqlite"
    var config = Configuration()
    config.foreignKeysEnabled = true
    return try DatabaseQueue(path: path, configuration: config)
  }

  static func insertCatalog(_ db: Database) throws {
    for ing in ingredients {
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [ing.id, "Ingredient \(ing.id)", ing.calories, ing.protein, ing.carbs, ing.fat, ing.fiber, ing.sugar, ing.sodium]
      )
    }
    for recipe in recipes {
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) VALUES (?, ?, ?, ?, ?, ?, ?)",
        arguments: [recipe.id, "Recipe \(recipe.id)", 15, recipe.servings, "cook", 0, "bundled"]
      )
      for line in recipe.lines {
        try db.execute(
          sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, ?, ?, ?)",
          arguments: [recipe.id, line.ingredientId, line.required, line.grams, "\(line.grams) g"]
        )
      }
    }
  }

  /// Seeds a meal the way the pre-snapshot app wrote history: raw history,
  /// swap rows, and composed inventory mutations — no snapshot.
  static func insertMeal(_ db: Database, _ meal: MealSpec) throws {
    if let cookedAt = meal.cookedAt {
      try db.execute(
        sql: "INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [meal.id, meal.recipeId, cookedAt, NSNull(), meal.servingsConsumed ?? NSNull(), meal.portion]
      )
    } else {
      try db.execute(
        sql: "INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier) VALUES (?, ?, NULL, ?, ?, ?)",
        arguments: [meal.id, meal.recipeId, NSNull(), meal.servingsConsumed ?? NSNull(), meal.portion]
      )
    }
    for swap in meal.swaps {
      try db.execute(
        sql: "INSERT INTO cooking_history_swaps (history_id, original_ingredient_id, substitute_ingredient_id, ratio) VALUES (?, ?, ?, ?)",
        arguments: [meal.id, swap.originalId, swap.substituteId, swap.ratio]
      )
    }
  }

  /// Composed inventory writes standing in for InventoryRepository's log-time
  /// consumption: a lot, its event, and the rolled-up item, plus a streak row.
  static func insertComposedLogWrites(_ db: Database, ingredientId: Int64, day: String) throws {
    try db.execute(
      sql: "INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams) VALUES (?, ?, ?)",
      arguments: [ingredientId, 500.0, 466.25]
    )
    try db.execute(
      sql: "INSERT INTO inventory_events (ingredient_id, event_type, quantity_delta_grams, reason) VALUES (?, ?, ?, ?)",
      arguments: [ingredientId, "consumption", -33.75, "meal"]
    )
    try db.execute(
      sql: "INSERT INTO inventory_items (ingredient_id, total_remaining_grams) VALUES (?, ?)",
      arguments: [ingredientId, 466.25]
    )
    try db.execute(
      sql: "INSERT INTO streaks (date, meals_cooked) VALUES (?, ?)",
      arguments: [day, 1]
    )
  }
}
