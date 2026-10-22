import GRDB
import Synchronization
import XCTest

@testable import FridgeLuck

@MainActor
final class GeneratedRecipeSafetyTests: XCTestCase {
  func testStoredAllergyBlocksGeneratedRecipeEvenWhenCallerPassesNoDiets() async throws {
    let (engine, health) = try makeEngine()
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[999]"
    try health.saveHealthProfile(profile)

    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)

    XCTAssertNil(engine.aiGeneratedRecipe, "An unstructured recipe cannot prove it avoids a flagged ingredient")
    XCTAssertNotNil(engine.aiEnhancementNotice)
  }

  func testStoredDietsBlockUnstructuredRecipes() async throws {
    let (engine, health) = try makeEngine()
    for diet in ["vegetarian", "pescatarian", "vegan", "keto"] {
      var profile = HealthProfile.default
      profile.dietaryRestrictions = "[\"\(diet)\"]"
      try health.saveHealthProfile(profile)
      await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
      XCTAssertNil(engine.aiGeneratedRecipe, diet)
    }
  }

  func testCallerRestrictionsAlsoBlockUnstructuredRecipes() async throws {
    let (engine, _) = try makeEngine()
    await engine.generateAIRecipe(
      ingredientNames: [], scanConfidenceScore: 1, dietaryRestrictions: ["milk"])
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  func testUnrestrictedHouseholdStillReceivesGeneration() async throws {
    let (engine, _) = try makeEngine()
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertEqual(engine.aiGeneratedRecipe?.title, "Peanut noodles")
  }

  func testMalformedStoredRestrictionsFailClosed() async throws {
    let (engine, health) = try makeEngine()
    for corruptAllergens in [true, false] {
      var profile = HealthProfile.default
      if corruptAllergens {
        profile.allergenIngredientIds = "not JSON"
      } else {
        profile.dietaryRestrictions = "not JSON"
      }
      try health.saveHealthProfile(profile)
      await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
      XCTAssertNil(engine.aiGeneratedRecipe)
    }
  }

  func testProfileReadFailureClearsPreviouslyGeneratedRecipe() async throws {
    let db = try DatabaseQueue()
    let (engine, _) = try makeEngine(db: db)
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertNotNil(engine.aiGeneratedRecipe)
    try await db.write { try $0.execute(sql: "DROP TABLE health_profile") }
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertNil(engine.aiGeneratedRecipe)
    XCTAssertNotNil(engine.aiEnhancementNotice)
  }

  func testNewRestrictionClearsPreviouslyGeneratedRecipe() async throws {
    let (engine, health) = try makeEngine()
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertNotNil(engine.aiGeneratedRecipe)
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[999]"
    try health.saveHealthProfile(profile)
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  func testRestrictionAddedWhileGenerationIsInFlightBlocksResult() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let health = HealthScoringService(nutritionService: NutritionService(db: db), db: db)
    let generator = FixedGenerator(beforeReturning: {
      var profile = HealthProfile.default
      profile.allergenIngredientIds = "[999]"
      try health.saveHealthProfile(profile)
    })
    let (engine, _) = try makeEngine(db: db, generator: generator)
    await engine.generateAIRecipe(ingredientNames: [], scanConfidenceScore: 1)
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  func testCloudResultIsRecheckedAgainstRestrictionsAddedDuringRequest() async throws {
    let db = try DatabaseQueue()
    let (_, health) = try makeEngine(db: db)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecipeResponseProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = try XCTUnwrap(URL(string: "https://recipe.test/\(UUID().uuidString)"))
    let endpoint = url.appendingPathComponent("v1/recipes/generate")
    defer { RecipeResponseProtocol.actions.withLock { $0.removeValue(forKey: endpoint) } }
    let cloud = GeminiCloudAgent(
      config: .init(apiKey: nil, modelName: "fixture", backendBaseURL: url), session: session)
    let (engine, _) = try makeEngine(db: db, cloud: cloud)

    await engine.generateAIRecipe(ingredientNames: ["noodles"], scanConfidenceScore: 0)
    XCTAssertEqual(engine.aiGeneratedRecipe?.title, "Cloud peanut noodles", "The real cloud decoder must run")

    RecipeResponseProtocol.actions.withLock { actions in
      actions[endpoint] = {
        var profile = HealthProfile.default
        profile.allergenIngredientIds = "[999]"
        try health.saveHealthProfile(profile)
      }
    }
    await engine.generateAIRecipe(ingredientNames: ["noodles"], scanConfidenceScore: 0)
    XCTAssertNil(engine.aiGeneratedRecipe)
  }

  private func makeEngine(
    db: DatabaseQueue? = nil, generator: FixedGenerator = FixedGenerator(),
    cloud: GeminiCloudAgent? = nil
  ) throws -> (RecommendationEngine, HealthScoringService) {
    let db = try db ?? DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let nutrition = NutritionService(db: db)
    let health = HealthScoringService(nutritionService: nutrition, db: db)
    let repository = RecipeRepository(
      db: db, nutritionService: nutrition, healthScoringService: health,
      personalizationService: PersonalizationService(db: db))
    return (RecommendationEngine(
      recipeRepository: repository, healthScoringService: health, recipeGenerator: generator,
      geminiCloudAgent: cloud), health)
  }
}

private final class RecipeResponseProtocol: URLProtocol, @unchecked Sendable {
  static let actions = Mutex<[URL: @Sendable () throws -> Void]>([:])

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recipe.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    do {
      let action = Self.actions.withLock { $0.removeValue(forKey: url) }
      try action?()
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = Data("""
        {"title":"Cloud peanut noodles","timeMinutes":10,"servings":1,
         "instructions":"Stir in peanut butter.","estimatedCaloriesPerServing":400}
        """.utf8)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private struct FixedGenerator: RecipeGenerating {
  var beforeReturning: (@Sendable () throws -> Void)? = nil
  var enhancementAvailability: AIEnhancementAvailability { .available }

  func generate(from ingredientNames: [String], dietaryRestrictions: [String]) async throws
    -> GeneratedRecipeResult?
  {
    try beforeReturning?()
    return GeneratedRecipeResult(
      title: "Peanut noodles", timeMinutes: 10, servings: 1,
      instructions: "Stir in peanut butter.", estimatedCaloriesPerServing: 400,
      isAIGenerated: true)
  }
}
