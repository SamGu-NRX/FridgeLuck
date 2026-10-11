import Foundation
import GRDB
@testable import RecipeQuantityReviewCheck

// MARK: - Database fixtures

/// Synthetic, migrated databases for the amount review tests. All inputs are synthetic:
/// no personal transcripts, no user data.
enum ReviewFixture {
  /// Ingredient row values: nutrition is stored per 100 g, matching the real schema.
  struct SeedIngredient {
    let id: Int64
    let name: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    init(_ id: Int64, _ name: String, _ calories: Double, _ protein: Double, _ carbs: Double, _ fat: Double) {
      self.id = id
      self.name = name
      self.calories = calories
      self.protein = protein
      self.carbs = carbs
      self.fat = fat
    }
  }

  struct SeedRecipe {
    let id: Int64
    let title: String
    let servings: Int

    init(_ id: Int64, _ title: String, _ servings: Int) {
      self.id = id
      self.title = title
      self.servings = servings
    }
  }

  struct SeedRow {
    let recipeID: Int64
    let ingredientID: Int64
    let isRequired: Bool
    let grams: Double
    let display: String

    init(_ recipeID: Int64, _ ingredientID: Int64, _ isRequired: Bool, _ grams: Double, _ display: String) {
      self.recipeID = recipeID
      self.ingredientID = ingredientID
      self.isRequired = isRequired
      self.grams = grams
      self.display = display
    }
  }

  /// In-memory migrated database.
  static func inMemory() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try DatabaseMigrations.migrate(queue)
    return queue
  }

  /// On-disk migrated database — used where the test must prove nothing was written.
  static func onDisk(at path: String) throws -> DatabaseQueue {
    if FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
    let queue = try DatabaseQueue(path: path)
    try DatabaseMigrations.migrate(queue)
    return queue
  }

  static func seed(
    _ db: DatabaseQueue,
    recipes: [SeedRecipe],
    ingredients: [SeedIngredient],
    rows: [SeedRow]
  ) throws {
    try db.write { db in
      for recipe in recipes {
        try db.execute(
          sql: """
            INSERT INTO recipes (id, title, time_minutes, servings, instructions)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [recipe.id, recipe.title, 20, recipe.servings, "Cook it."])
      }
      for ingredient in ingredients {
        try db.execute(
          sql: """
            INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            ingredient.id, ingredient.name, ingredient.calories,
            ingredient.protein, ingredient.carbs, ingredient.fat,
          ])
      }
      for row in rows {
        try db.execute(
          sql: """
            INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [row.recipeID, row.ingredientID, row.isRequired, row.grams, row.display])
      }
    }
  }

  /// Full content dump of every user table, in a deterministic order. Two dumps of an
  /// unchanged database are byte-identical; any write would show up as a difference.
  static func contentDump(_ path: String) throws -> String {
    var config = Configuration()
    config.readonly = true
    let queue = try DatabaseQueue(path: path, configuration: config)
    return try queue.read { db in
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          ORDER BY name
          """)
      var out = ""
      for table in tables {
        out += "== \(table)\n"
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY 1, 2")
        for row in rows {
          out += row.description + "\n"
        }
      }
      return out
    }
  }
}

// MARK: - Mirrored production reader

/// Mirrors the app target's `AppRecipeQuantityReviewReader`: the identical mapping of the
/// real synchronous services onto the FeatureLogic session, over real GRDB reads. The
/// app target itself cannot be imported on Linux; see this package's README.
struct ReaderAdapter: RecipeQuantityReviewReading {
  let recipeRepository: RecipeRepository
  let nutritionService: NutritionService
  let activeSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)]

  func fetchRecipeServings(id: Int64) throws -> Int? {
    try recipeRepository.fetchRecipe(id: id)?.servings
  }

  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    try recipeRepository.ingredientsForRecipe(id: recipeID).map { item in
      let substitute = activeSubstitutions[item.quantity.ingredientId]
      return QuantityReviewJoinedRow(
        ingredientID: item.quantity.ingredientId,
        recipeID: item.quantity.recipeId,
        isRequired: item.quantity.isRequired,
        quantityGrams: item.quantity.quantityGrams,
        displayName: item.ingredient.displayName,
        substituteID: substitute?.substitution.substituteId,
        substituteName: substitute?.ingredient.displayName,
        substituteRatio: substitute.map { $0.substitution.ratio })
    }
  }

  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    let macros = try nutritionService.ingredientMacros(ingredientId: ingredientID, grams: grams)
    return QuantityReviewNutrition(
      calories: macros.caloriesPerServing,
      protein: macros.proteinPerServing,
      carbs: macros.carbsPerServing,
      fat: macros.fatPerServing)
  }

  func referencePerServingCalories(recipeID: Int64) throws -> Double? {
    try nutritionService.macros(for: recipeID, swaps: []).caloriesPerServing
  }
}

// MARK: - Test-only readers

/// Reader whose reads block on a gate so the test can cancel the load mid-sequence.
final class GatedReader: RecipeQuantityReviewReading, @unchecked Sendable {
  private let lock = NSLock()
  private var _joinedCalls = 0
  private var _servingCalls = 0
  let joinedEntered = DispatchSemaphore(value: 0)
  let releaseJoined = DispatchSemaphore(value: 0)

  var joinedCalls: Int {
    lock.lock(); defer { lock.unlock() }
    return _joinedCalls
  }
  var servingCalls: Int {
    lock.lock(); defer { lock.unlock() }
    return _servingCalls
  }

  func fetchRecipeServings(id: Int64) throws -> Int? {
    lock.lock(); _servingCalls += 1; lock.unlock()
    return 4
  }

  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    lock.lock(); _joinedCalls += 1; lock.unlock()
    // Signal the test, then block until it releases — cancellation lands while blocked.
    joinedEntered.signal()
    releaseJoined.wait()
    try Task.checkCancellation()
    return [
      QuantityReviewJoinedRow(
        ingredientID: 1, recipeID: recipeID, isRequired: true,
        quantityGrams: 100, displayName: "Chicken")
    ]
  }

  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    QuantityReviewNutrition(calories: 100, protein: 0, carbs: 0, fat: 0)
  }

  func referencePerServingCalories(recipeID: Int64) throws -> Double? { 250 }
}

/// Reader that fails every read, to surface read failures as refusals.
struct FailingReader: RecipeQuantityReviewReading {
  struct Boom: Error {}

  func fetchRecipeServings(id: Int64) throws -> Int? { throw Boom() }
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] { throw Boom() }
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    throw Boom()
  }
  func referencePerServingCalories(recipeID: Int64) throws -> Double? { throw Boom() }
}
