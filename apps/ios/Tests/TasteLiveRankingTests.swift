import FLFeatureLogic
import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// The learned residual layer wired into the app surfaces: the live ranker over a
/// recommendation pool, exposure logging (docs/spec/taste/SPEC.md §2.4), the stored
/// default-off gate from the committed v2 catalog gate report, and bundle-v2 profile
/// evidence with canonical keys and vocabulary display names.
final class TasteLiveRankingTests: XCTestCase {
  // MARK: - Fixtures

  /// Near-tied A/B under a well-ahead C: the learned layer may flip A/B but the
  /// rule gap to C must survive.
  private let ruleScores = ["A": 50.0, "B": 49.95, "C": 70.0]

  private let featureKeysByRecipe = [
    "A": ["ingredient:chicken_breast"],
    "B": ["ingredient:tofu"],
    "C": ["ingredient:pasta"],
  ]

  private let nameOf = [
    "ingredient:chicken_breast": "chicken breast",
    "ingredient:tofu": "tofu",
    "ingredient:pasta": "pasta",
  ]

  private func makeCatalogIndex() -> TasteCatalogFeatureIndex {
    TasteCatalogFeatureIndex(
      featureKeysByRecipe: [
        "rcp-000001": ["ingredient:chicken_breast"],
        "rcp-000002": ["ingredient:tofu"],
        "rcp-000003": ["ingredient:pasta"],
      ],
      nameOf: nameOf,
      successorCatalogIdByLegacyRecipe: [
        "1": "rcp-000001", "2": "rcp-000002", "3": "rcp-000003",
      ],
      canonicalKeyByLegacyIngredient: ["7": "tofu"])
  }

  private func cookedEvent(
    id: String, at: Date, recipeId: String, rating: Int
  ) -> TasteEvent {
    TasteEvent(
      id: id, at: TasteTimestamp.string(from: at), kind: "recipe_cooked",
      recipe: TasteRecipeRef(id: recipeId, source: "catalog"), surface: "cook.complete",
      payload: ["rating": .number(Double(rating))])
  }

  private func threeBadCooks(of recipeId: String) -> [TasteEvent] {
    (0..<3).map { index in
      cookedEvent(
        id: "cook-\(recipeId)-\(index)",
        at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
        recipeId: recipeId, rating: 1)
    }
  }

  private func makeService() throws -> (
    service: TasteResidualRankingService, store: TasteEventStore
  ) {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    let store = TasteEventStore(db: dbQueue)
    let service = TasteResidualRankingService(
      store: store,
      personalization: PersonalizationService(db: dbQueue),
      catalogIndex: makeCatalogIndex())
    return (service, store)
  }

  private func scored(_ id: Int64, rankingScore: Double) -> ScoredRecipe {
    ScoredRecipe(
      recipe: Recipe(
        id: id, title: "Recipe \(id)", timeMinutes: 10, servings: 1, instructions: "Cook.",
        tags: 0, source: .bundled, createdAt: nil),
      matchedRequired: 1,
      totalRequired: 1,
      matchedOptional: 0,
      missingRequiredCount: 0,
      missingIngredientIds: [],
      macros: RecipeMacros(
        caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
        fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
      healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
      personalScore: 0,
      rankingScore: rankingScore,
      rankingReasons: [],
      matchTier: .exact)
  }

  private func ruleOrder() -> [String] {
    ["C", "A", "B"]  // rule scores 70 / 50 / 49.95
  }

  private func withResidualEnabled<T>(
    _ body: () throws -> T
  ) rethrows -> T {
    UserDefaults.standard.set(true, forKey: TasteResidualSettings.storageKey)
    defer { UserDefaults.standard.removeObject(forKey: TasteResidualSettings.storageKey) }
    return try body()
  }

  // MARK: - Residual ranking behavior

  func testResidualNudgesNearTiesWithoutOverturningRuleGaps() {
    let events = threeBadCooks(of: "A")
    let order = TasteResidualRankingService.ranked(
      poolKeys: ruleOrder(), ruleScores: ruleScores, events: events, exposures: [],
      featureKeysByRecipe: featureKeysByRecipe, nameOf: nameOf,
      evalAt: Date(timeIntervalSince1970: 2_000_000))

    // The badly-rated near-tie flips under the learned layer; the 20-point rule
    // gap to C does not.
    XCTAssertEqual(order, ["C", "B", "A"])
  }

  func testGlobalClampBoundsTheLearnedContribution() {
    // cap["ingredient"] = 4.0 bounds one feature at d*c*4 <= 4; the rank-time
    // GLOBAL_CLAMP = 8.0 only binds on the SUM across a recipe's features, so
    // this fixture gives A three ingredient features and enough one-star cooks
    // to saturate each at -4: the sum (-12) must clamp to exactly -8 (SPEC 9:
    // the learned layer can reorder near-ties, never bury a clearly better
    // recipe).
    let threeFeatureIndex = [
      "A": ["ingredient:a1", "ingredient:a2", "ingredient:a3"],
      "B": ["ingredient:tofu"],
      "C": ["ingredient:pasta"],
    ]
    let events = (0..<300).map { index in
      cookedEvent(
        id: "cook-\(index)", at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
        recipeId: "A", rating: 1)
    }
    var engine = TasteResidualEngine(featureKeysByRecipe: threeFeatureIndex, nameOf: nameOf)
    engine.ingest(events: events, exposures: [], statements: [])
    let ranked = engine.rank(
      ruleScores: ruleScores, evalAt: TasteTimestamp.string(from: Date(timeIntervalSince1970: 2_000_000)))

    let a = ranked.first { $0.recipeID == "A" }
    XCTAssertEqual(a?.recipeID, "A")
    // The rank-time clamp bounds the contribution applied to the rule score;
    // learnedContribution carries the raw sum across features (each feature
    // contribution is individually capped at ±4, and their sum here exceeds 8).
    XCTAssertEqual(
      TasteResidualEngine.f6((a?.totalScore ?? 0) - ruleScores["A"]!),
      TasteResidualEngine.f6(-8.0))
    // And no entry's applied contribution ever leaves the clamp band.
    for entry in ranked {
      XCTAssertLessThanOrEqual(abs(entry.totalScore - ruleScores[entry.recipeID]!), 8.0)
    }
  }

  func testSkipsResolveOnlyAgainstLoggedExposures() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let exposure = TasteExposure(
      id: "exp-1", at: TasteTimestamp.string(from: now.addingTimeInterval(-60)),
      surface: "home.tonight",
      slate: [TasteSlateItem(position: 0, recipe: TasteRecipeRef(id: "A"))],
      feasible: [.string("A"), .string("B")])

    func order(skipEventId: String, exposureId: String) -> [String] {
      let skip = TasteEvent(
        id: skipEventId, at: TasteTimestamp.string(from: now), kind: "recipe_skipped",
        recipe: TasteRecipeRef(id: "A", source: "catalog"), surface: "home.tonight",
        payload: ["exposureId": .string(exposureId)])
      return TasteResidualRankingService.ranked(
        poolKeys: ruleOrder(), ruleScores: ruleScores, events: [skip], exposures: [exposure],
        featureKeysByRecipe: featureKeysByRecipe, nameOf: nameOf, evalAt: now)
    }

    // A skip against the logged slate is taste: the skipped near-tie loses its
    // lead.
    XCTAssertEqual(order(skipEventId: "skip-logged", exposureId: "exp-1"), ["C", "B", "A"])
    // A skip whose exposureId resolves to nothing logged is not taste: the
    // rule order stands (SPEC 9).
    XCTAssertEqual(
      order(skipEventId: "skip-unlogged", exposureId: "exp-not-logged"), ["C", "A", "B"])
  }

  // MARK: - Stored gate

  func testDefaultFollowsTheCommittedGateDecision() {
    UserDefaults.standard.removeObject(forKey: TasteResidualSettings.storageKey)
    // Gate report 2026-10-15 (evaluation/taste-lab/results/catalog-v2-gate.md):
    // seed 7's delta CI spans zero and churn runs 3-5x the legacy band, so the
    // learned layer ships off until the offline rerun confirms it.
    XCTAssertFalse(TasteResidualSettings.builtInDefault)
    XCTAssertFalse(TasteResidualSettings.isEnabled)

    UserDefaults.standard.set(true, forKey: TasteResidualSettings.storageKey)
    XCTAssertTrue(TasteResidualSettings.isEnabled)
    UserDefaults.standard.removeObject(forKey: TasteResidualSettings.storageKey)
    XCTAssertFalse(TasteResidualSettings.isEnabled)
  }

  // MARK: - Pool application (service over the real store)

  func testApplyReordersThePoolAndLogsTheExposure() throws {
    let (service, store) = try makeService()
    // Three one-star cooks of pool entry 1, logged the way the cook flow
    // writes them (typed cooked payload, legacy successor id).
    for index in 0..<3 {
      try store.append(
        TasteEventRecord(
          at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
          recipe: TasteRecipeRef(id: "1", revision: nil, source: "catalog"),
          surface: TasteSurface.cookComplete,
          payload: .cooked(
            TasteCookedPayload(
              cookSessionId: nil, exposureId: nil, rating: 1, servings: 2,
              slatePosition: nil, wouldMakeAgain: nil))))
    }
    let pool = [scored(3, rankingScore: 70), scored(1, rankingScore: 50), scored(2, rankingScore: 49.95)]

    let ordered = try withResidualEnabled {
      service.apply(
        to: pool, surface: TasteSurface.homeTonight, shownCount: 4,
        now: Date(timeIntervalSince1970: 2_000_000))
    }

    // Legacy ids resolve to the superseding catalog rows' features through the
    // index's successor bridges, so the logged events reach the ranker.
    XCTAssertEqual(ordered.map { $0.recipe.id }, [3, 2, 1])

    // One render = one exposure: the whole pool as the feasible set, the shown
    // prefix as the slate.
    XCTAssertEqual(try store.exposureCount(), 1)
    let exposure = try XCTUnwrap(try store.allExposures().first)
    XCTAssertEqual(exposure.exposure.surface, TasteSurface.homeTonight)
    XCTAssertEqual(exposure.exposure.slate.count, 3)
    XCTAssertEqual(exposure.exposure.slate.map(\.position), [0, 1, 2])
    // The slate logs the displayed (learned) order — the exposure records what
    // the user actually saw, not the rule order the layer overrode.
    XCTAssertEqual(exposure.exposure.slate.map { $0.recipe.id }, ["3", "2", "1"])
    XCTAssertEqual(exposure.exposure.feasibleCount, 3)
  }

  func testApplyWithLearningDisabledKeepsRuleOrderButStillLogsTheExposure() throws {
    let (service, store) = try makeService()
    for index in 0..<3 {
      try store.append(
        TasteEventRecord(
          at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
          recipe: TasteRecipeRef(id: "1", revision: nil, source: "catalog"),
          surface: TasteSurface.cookComplete,
          payload: .cooked(
            TasteCookedPayload(
              cookSessionId: nil, exposureId: nil, rating: 1, servings: 2,
              slatePosition: nil, wouldMakeAgain: nil))))
    }
    let pool = [scored(3, rankingScore: 70), scored(1, rankingScore: 50), scored(2, rankingScore: 49.95)]
    UserDefaults.standard.removeObject(forKey: TasteResidualSettings.storageKey)

    let ordered = service.apply(
      to: pool, surface: TasteSurface.homeTonight, shownCount: 4,
      now: Date(timeIntervalSince1970: 2_000_000))

    // Default-off: the rule order survives untouched...
    XCTAssertEqual(ordered.map { $0.recipe.id }, [3, 1, 2])
    // ...but the render is still instrumented, so skip/view evidence can be
    // resolved later once the gate flips.
    XCTAssertEqual(try store.exposureCount(), 1)
  }

  func testApplyHandlesEmptyPoolsAndDuplicateIdentityKeys() throws {
    let (service, _) = try makeService()
    XCTAssertTrue(try withResidualEnabled { service.apply(to: [], surface: "home.tonight", now: Date()) }.isEmpty)

    // Two unsaved drafts share a title and therefore an event key; reordering
    // them would join unrelated events to one entry, so the learned layer skips
    // and the pool order stands. The differing rule scores discriminate pool
    // order from the engine's deterministic tiebreak.
    let pool = [
      scored(1, rankingScore: 50),
      ScoredRecipe(
        recipe: Recipe(
          id: nil, title: "Ditto", timeMinutes: 10, servings: 1, instructions: "Cook.",
          tags: 0, source: .aiGenerated, createdAt: nil),
        matchedRequired: 1, totalRequired: 1, matchedOptional: 0, missingRequiredCount: 0,
        missingIngredientIds: [],
        macros: RecipeMacros(
          caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
          fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
        healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
        personalScore: 0, rankingScore: 40, rankingReasons: [], matchTier: .nearMatch),
      ScoredRecipe(
        recipe: Recipe(
          id: nil, title: "Ditto", timeMinutes: 15, servings: 2, instructions: "Cook.",
          tags: 0, source: .aiGenerated, createdAt: nil),
        matchedRequired: 1, totalRequired: 1, matchedOptional: 0, missingRequiredCount: 0,
        missingIngredientIds: [],
        macros: RecipeMacros(
          caloriesPerServing: 100, proteinPerServing: 5, carbsPerServing: 10, fatPerServing: 3,
          fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 100),
        healthScore: HealthScore(rating: 3, label: "Moderate", reasoning: ""),
        personalScore: 0, rankingScore: 41, rankingReasons: [], matchTier: .nearMatch),
    ]
    let ordered = try withResidualEnabled {
      service.apply(to: pool, surface: "home.tonight", shownCount: 4, now: Date())
    }
    XCTAssertEqual(ordered.count, 3)
    XCTAssertEqual(ordered[0].recipe.id, 1)
    XCTAssertEqual(ordered[1].rankingScore, 40)
    XCTAssertEqual(ordered[2].rankingScore, 41)
  }

  // MARK: - Bundle-v2 profile evidence

  func testProfileBuildsCatalogEvidenceFromTheV2Vocabulary() async throws {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    let store = TasteEventStore(db: dbQueue)
    let repository = TasteProfileRepository(
      dbQueue: dbQueue, store: store, catalogIndex: makeCatalogIndex())

    // Catalog cooks logged under the legacy successor id, as the cook flow
    // writes them.
    for (index, rating) in [1, 2].enumerated() {
      try store.append(
        TasteEventRecord(
          at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
          recipe: TasteRecipeRef(id: "1", revision: 1, source: "catalog"),
          surface: TasteSurface.cookComplete,
          payload: .cooked(
            TasteCookedPayload(
              cookSessionId: nil, exposureId: nil, rating: rating, servings: 2,
              slatePosition: nil, wouldMakeAgain: nil))))
    }

    let evidence = try await repository.loadEvidence()
    let lowRating = try XCTUnwrap(
      evidence.first { $0.claim == .lowRating && $0.featureKey == "ingredient:chicken_breast" })
    // Canonical v2 keys, not the legacy numeric ids.
    XCTAssertEqual(lowRating.featureName, "chicken breast")
    XCTAssertEqual(lowRating.numerator, 2)
    XCTAssertEqual(lowRating.denominator, 2)
    XCTAssertNotNil(lowRating.lastEvidenceAt)
  }

  func testProfileNamesLegacySubstitutionIdsThroughTheVocabularyBridge() async throws {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    let store = TasteEventStore(db: dbQueue)
    let repository = TasteProfileRepository(
      dbQueue: dbQueue, store: store, catalogIndex: makeCatalogIndex())

    // A substitution event logs the legacy numeric ingredient id (7 → tofu in
    // the fixture bridge); the evidence lands on the canonical key.
    try store.append(
      TasteEventRecord(
        at: Date(timeIntervalSince1970: 1_000_000),
        ingredient: 7,
        surface: TasteSurface.cookIngredients,
        payload: .substituted(
          TasteSubstitutionPayload(
            cookEventId: "cook-1", motivation: .preferred, ratio: nil,
            substituteIngredientId: 9))))

    let evidence = try await repository.loadEvidence()
    let substituted = try XCTUnwrap(evidence.first { $0.claim == .substitutedAway })
    XCTAssertEqual(substituted.featureKey, "ingredient:tofu")
    XCTAssertEqual(substituted.featureName, "tofu")
    XCTAssertEqual(substituted.numerator, 1)
    XCTAssertEqual(substituted.denominator, 1)
  }

  func testProfileKeepsLegacyFeatureTablesWhenTheIndexDoesNotCoverARecipe() async throws {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try await dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (42, 'Legacy Stew', 30, 2, 'Cook.')
          """)
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (5, 'Lamb', 294, 25, 0, 21)")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (42, 5, 1, 200, '200 g')
          """)
    }
    let store = TasteEventStore(db: dbQueue)
    let repository = TasteProfileRepository(
      dbQueue: dbQueue, store: store, catalogIndex: makeCatalogIndex())

    try store.append(
      TasteEventRecord(
        id: "cook-42",
        at: Date(timeIntervalSince1970: 1_000_000),
        recipe: TasteRecipeRef(id: "42", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.cookComplete,
        payload: .cooked(
          TasteCookedPayload(
            cookSessionId: nil, exposureId: nil, rating: 1, servings: 2,
            slatePosition: nil, wouldMakeAgain: nil)),
        cookEventId: "cook-42"))

    // Recipe 42 is outside the bundle: the legacy recipe_ingredients tables
    // carry the evidence, keyed and named the legacy way.
    let evidence = try await repository.loadEvidence()
    let lowRating = try XCTUnwrap(
      evidence.first { $0.claim == .lowRating }, "evidence was \(evidence)")
    XCTAssertEqual(lowRating.featureKey, "ingredient:5")
    XCTAssertEqual(lowRating.featureName, "Lamb")
    XCTAssertEqual(lowRating.numerator, 1)
    XCTAssertEqual(lowRating.denominator, 1)
  }

  func testProfileWithoutAnIndexReproducesTheLegacyPath() async throws {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try await dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (42, 'Legacy Stew', 30, 2, 'Cook.')
          """)
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (5, 'Lamb', 294, 25, 0, 21)")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (42, 5, 1, 200, '200 g')
          """)
    }
    let store = TasteEventStore(db: dbQueue)
    let repository = TasteProfileRepository(dbQueue: dbQueue, store: store)

    try store.append(
      TasteEventRecord(
        id: "cook-42",
        at: Date(timeIntervalSince1970: 1_000_000),
        recipe: TasteRecipeRef(id: "42", revision: 1, source: TasteRecipeSource.catalog.rawValue),
        surface: TasteSurface.cookComplete,
        payload: .cooked(
          TasteCookedPayload(
            cookSessionId: nil, exposureId: nil, rating: 1, servings: 2,
            slatePosition: nil, wouldMakeAgain: nil)),
        cookEventId: "cook-42"))

    let evidence = try await repository.loadEvidence()
    let lowRating = try XCTUnwrap(
      evidence.first { $0.claim == .lowRating }, "evidence was \(evidence)")
    XCTAssertEqual(lowRating.featureKey, "ingredient:5")
    XCTAssertEqual(lowRating.featureName, "Lamb")
  }
}
