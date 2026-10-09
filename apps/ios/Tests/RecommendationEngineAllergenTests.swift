import FLFeatureLogic
import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// Pins the allergen safety contract of `RecommendationEngine.generateAIRecipe`:
/// the user's resolved allergen names reach the generator as `avoidIngredients`,
/// an avoid list that cannot be established stops generation before any generator
/// call, and a generated recipe the screening rejects is treated as no result.
/// Only a local fake generator is exercised — the cloud path stays nil.
@MainActor
final class RecommendationEngineAllergenTests: XCTestCase {
  func testGenerateAIRecipePassesResolvedAllergenNamesToGenerator() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[7]")
    try insertIngredient(id: 7, name: "Peanuts", into: dbQueue)
    let generator = FakeRecipeGenerator(scriptedResults: [recipeResult(title: "Herb Omelette")])
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: IngredientRepository(db: dbQueue)
    )

    await engine.generateAIRecipe(ingredientNames: ["Tomato", "Onion"])

    let calls = generator.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.avoidIngredients, ["Peanuts"])
  }

  func testGenerateAIRecipePassesEmptyListWhenNoAllergens() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[]")
    let generator = FakeRecipeGenerator(scriptedResults: [recipeResult(title: "Herb Omelette")])
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: IngredientRepository(db: dbQueue)
    )

    await engine.generateAIRecipe(ingredientNames: ["Tomato", "Onion"])

    let calls = generator.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.avoidIngredients, [])
  }

  func testUnsafeGeneratedRecipeIsNotShown() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[7]")
    try insertIngredient(id: 7, name: "Peanuts", into: dbQueue)
    let generator = FakeRecipeGenerator(
      scriptedResults: [
        recipeResult(
          title: "Peanut Sauce Noodles",
          instructions: "Boil the noodles and toss with the sauce."
        )
      ]
    )
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: IngredientRepository(db: dbQueue)
    )

    await engine.generateAIRecipe(ingredientNames: ["Noodles", "Eggs"])

    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  func testSafeGeneratedRecipeIsShown() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[7]")
    try insertIngredient(id: 7, name: "Peanuts", into: dbQueue)
    let generator = FakeRecipeGenerator(
      scriptedResults: [
        recipeResult(
          title: "Herb Omelette",
          instructions: "Whisk the eggs with herbs and cook slowly in a buttered pan."
        )
      ]
    )
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: IngredientRepository(db: dbQueue)
    )

    await engine.generateAIRecipe(ingredientNames: ["Eggs", "Herbs"])

    let recipe = try XCTUnwrap(engine.aiGeneratedRecipe)
    XCTAssertEqual(recipe.title, "Herb Omelette")
  }

  func testUnresolvableAllergenIDFailsClosed() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[999]")
    let generator = FakeRecipeGenerator(scriptedResults: [recipeResult(title: "Herb Omelette")])
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: IngredientRepository(db: dbQueue)
    )

    await engine.generateAIRecipe(ingredientNames: ["Tomato", "Onion"])

    XCTAssertTrue(generator.calls.isEmpty)
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  func testNilIngredientRepositoryWithAllergensFailsClosed() async throws {
    let dbQueue = try makeDatabase(allergenIdsJSON: "[7]")
    try insertIngredient(id: 7, name: "Peanuts", into: dbQueue)
    let generator = FakeRecipeGenerator(scriptedResults: [recipeResult(title: "Herb Omelette")])
    let engine = makeEngine(
      dbQueue: dbQueue,
      recipeGenerator: generator,
      ingredientRepository: nil
    )

    await engine.generateAIRecipe(ingredientNames: ["Tomato", "Onion"])

    XCTAssertTrue(generator.calls.isEmpty)
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  // MARK: - Fixtures

  /// In-memory database with the real migrations (the NotificationCoordinatorTests
  /// pattern) plus a health_profile row carrying the given allergen ID list.
  private func makeDatabase(allergenIdsJSON: String) throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO health_profile
            (id, display_name, goal, dietary_restrictions, allergen_ingredient_ids)
          VALUES (1, 'Test Cook', 'general', '[]', ?)
          """,
        arguments: [allergenIdsJSON]
      )
    }
    return dbQueue
  }

  private func insertIngredient(id: Int64, name: String, into dbQueue: DatabaseQueue) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
          VALUES (?, ?, 0, 0, 0, 0, 0, 0, 0)
          """,
        arguments: [id, name]
      )
    }
  }

  private func makeEngine(
    dbQueue: DatabaseQueue,
    recipeGenerator: RecipeGenerating,
    ingredientRepository: IngredientRepository?
  ) -> RecommendationEngine {
    let nutritionService = NutritionService(db: dbQueue)
    let healthScoringService = HealthScoringService(nutritionService: nutritionService, db: dbQueue)
    let recipeRepository = RecipeRepository(
      db: dbQueue,
      nutritionService: nutritionService,
      healthScoringService: healthScoringService,
      personalizationService: PersonalizationService(db: dbQueue)
    )
    return RecommendationEngine(
      recipeRepository: recipeRepository,
      healthScoringService: healthScoringService,
      recipeGenerator: recipeGenerator,
      ingredientRepository: ingredientRepository
    )
  }

  private func recipeResult(
    title: String,
    instructions: String = "Cook the ingredients and serve."
  ) -> GeneratedRecipeResult {
    GeneratedRecipeResult(
      title: title,
      timeMinutes: 15,
      servings: 2,
      instructions: instructions,
      estimatedCaloriesPerServing: 350,
      isAIGenerated: true
    )
  }
}

/// Records every generation call and replays scripted results. Implements both the
/// extended `generate(from:dietaryRestrictions:avoidIngredients:)` shape and the
/// legacy two-argument shape, so the conformance holds either way the protocol evolves.
private final class FakeRecipeGenerator: RecipeGenerating, @unchecked Sendable {
  struct Call: Equatable {
    var ingredientNames: [String]
    var dietaryRestrictions: [String]
    var avoidIngredients: [String]
  }

  private let lock = NSLock()
  private var scriptedResults: [GeneratedRecipeResult?]
  private var callsStorage: [Call] = []

  init(scriptedResults: [GeneratedRecipeResult?]) {
    self.scriptedResults = scriptedResults
  }

  /// Calls recorded so far, in order.
  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return callsStorage
  }

  var enhancementAvailability: AIEnhancementAvailability { .available }

  func generate(
    from ingredientNames: [String],
    dietaryRestrictions: [String]
  ) async throws -> GeneratedRecipeResult? {
    try await generate(
      from: ingredientNames,
      dietaryRestrictions: dietaryRestrictions,
      avoidIngredients: []
    )
  }

  func generate(
    from ingredientNames: [String],
    dietaryRestrictions: [String],
    avoidIngredients: [String]
  ) async throws -> GeneratedRecipeResult? {
    lock.lock()
    defer { lock.unlock() }
    callsStorage.append(
      Call(
        ingredientNames: ingredientNames,
        dietaryRestrictions: dietaryRestrictions,
        avoidIngredients: avoidIngredients
      )
    )
    return scriptedResults.isEmpty ? nil : scriptedResults.removeFirst()
  }
}
