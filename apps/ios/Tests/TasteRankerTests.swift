import XCTest

@testable import FLFeatureLogic

/// Golden-fixture parity: the Swift engine must reproduce the Python lab's
/// engine byte-for-byte (f6-rounded) on the committed fixtures, plus unit
/// checks for the cold-start, SPEC 9, and determinism behaviors.
final class TasteRankerTests: XCTestCase {
  // #filePath = <repo>/apps/ios/Tests/TasteRankerTests.swift
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/
    .deletingLastPathComponent()  // ios/
    .deletingLastPathComponent()  // apps/
    .deletingLastPathComponent()  // repo root

  static let fixturesDir = repoRoot.appendingPathComponent("evaluation/taste-lab/fixtures")
  static let catalogURL =
    repoRoot.appendingPathComponent("apps/ios/Resources/RecipeCatalog/recipes-v2.json")

  private func loadCatalogFeatures() throws -> (
    featureKeysByRecipe: [String: [String]], nameOf: [String: String]
  ) {
    // The lab's committed fixtures are regenerated over the shipped bundle-v2
    // catalog (see evaluation/taste-lab/results/catalog-v2-gate.md); parity
    // runs against the same catalog through the v2 extractor.
    let data = try Data(contentsOf: Self.catalogURL)
    let bundle = try RecipeBundleV2.decode(from: data)
    return TasteFeatureExtractorV2.extractCatalog(bundle: bundle)
  }

  // MARK: Golden fixtures

  func testGoldenFixturesReplayExactly() throws {
    let catalog = try loadCatalogFeatures()
    let fixtures = try TasteFixture.loadAll(fromDirectory: Self.fixturesDir)
    XCTAssertGreaterThanOrEqual(fixtures.count, 3, "expected the hh00/hh01/hh23 fixtures")

    for fixture in fixtures {
      var engine = TasteResidualEngine(
        featureKeysByRecipe: catalog.featureKeysByRecipe, nameOf: catalog.nameOf)
      engine.ingest(
        events: fixture.events, exposures: fixture.exposures, statements: fixture.statements)
      let ranked = engine.rank(ruleScores: fixture.ruleScores, evalAt: fixture.evalAt)

      XCTAssertEqual(
        ranked.map(\.recipeID), fixture.expectedRanking.map(\.recipeId),
        "\(fixture.name): ranking order mismatch")

      for (got, expected) in zip(ranked, fixture.expectedRanking) {
        XCTAssertEqual(
          TasteResidualEngine.f6(got.ruleScore), expected.ruleScore,
          "\(fixture.name): \(got.recipeID) ruleScore")
        XCTAssertEqual(
          got.learnedFeatures.map(\.featureKey), expected.learnedFeatures.map(\.featureKey),
          "\(fixture.name): \(got.recipeID) feature keys")
        for (gotF, expF) in zip(got.learnedFeatures, expected.learnedFeatures) {
          XCTAssertEqual(
            TasteResidualEngine.f6(gotF.contribution), expF.contribution,
            "\(fixture.name): \(got.recipeID) contribution \(gotF.featureKey)")
        }
        XCTAssertEqual(
          TasteResidualEngine.f6(got.learnedContribution), expected.learnedContribution,
          "\(fixture.name): \(got.recipeID) learnedContribution")
        XCTAssertEqual(
          TasteResidualEngine.f6(got.totalScore), expected.totalScore,
          "\(fixture.name): \(got.recipeID) totalScore")
      }

      let (rendered, hidden) = engine.profile(evalAt: fixture.evalAt)
      XCTAssertEqual(
        rendered.map(\.id), fixture.expectedProfile.map(\.id),
        "\(fixture.name): profile statement order")
      XCTAssertEqual(
        hidden.map { "\($0.featureKey)|\($0.reason)" },
        fixture.expectedHidden.map { "\($0.featureKey)|\($0.reason)" },
        "\(fixture.name): hidden statements")
    }
  }

  // MARK: Cold start (no gate; shrinkage carries the safety)

  func testColdStartContributionsAreZeroAndRankingFollowsRules() throws {
    let catalog = try loadCatalogFeatures()
    let engine = TasteResidualEngine(featureKeysByRecipe: catalog.featureKeysByRecipe)
    let fixture = try TasteFixture.loadAll(fromDirectory: Self.fixturesDir).first!

    let ranked = engine.rank(ruleScores: fixture.ruleScores, evalAt: fixture.evalAt)
    // Priors (1,1) mean d = 0, so every contribution is exactly 0 and the
    // learned layer is a no-op: order matches rule score + id tiebreak.
    let ruleOrder = fixture.ruleScores
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .map(\.key)
    XCTAssertEqual(ranked.map(\.recipeID), ruleOrder)
    for entry in ranked {
      XCTAssertEqual(entry.learnedContribution, 0.0)
      XCTAssertEqual(entry.totalScore, TasteResidualEngine.f6(entry.ruleScore))
    }
    let (rendered, _) = engine.profile(evalAt: fixture.evalAt)
    XCTAssertTrue(rendered.isEmpty, "no statements before any evidence")
  }

  // MARK: Determinism

  func testReplayIsDeterministic() throws {
    let catalog = try loadCatalogFeatures()
    let fixture = try TasteFixture.loadAll(fromDirectory: Self.fixturesDir).first!

    func run() -> [TasteRankEntry] {
      var engine = TasteResidualEngine(
        featureKeysByRecipe: catalog.featureKeysByRecipe, nameOf: catalog.nameOf)
      engine.ingest(
        events: fixture.events.shuffled(), exposures: fixture.exposures,
        statements: fixture.statements)
      return engine.rank(ruleScores: fixture.ruleScores, evalAt: fixture.evalAt)
    }

    // Shuffled ingestion must not matter: the engine sorts by (at, id).
    let a = run()
    let b = run()
    XCTAssertEqual(a.map(\.recipeID), b.map(\.recipeID))
    XCTAssertEqual(a.map(\.totalScore), b.map(\.totalScore))
    XCTAssertEqual(a.map(\.learnedFeatures), b.map(\.learnedFeatures))
  }

  // MARK: SPEC 9 — interactions outside the logged slate are not taste

  func testSkipOutsideSlateIsIgnored() {
    let exposure = TasteExposure(
      id: "x1", at: "2026-01-01T00:00:00Z", surface: "plan",
      slate: [TasteSlateItem(position: 0, recipe: TasteRecipeRef(id: "other"))],
      feasible: [.string("r1"), .string("other")])
    let skip = TasteEvent(
      id: "e1", at: "2026-01-02T00:00:00Z", kind: "recipe_skipped",
      recipe: TasteRecipeRef(id: "r1"), payload: ["exposureId": .string("x1")])
    var engine = TasteResidualEngine(featureKeysByRecipe: ["r1": ["cuisine:asian"]])
    engine.ingest(events: [skip], exposures: [exposure])

    let contribs = engine.contributions(evalAt: "2026-01-03T00:00:00Z")
    let contribution = contribs["cuisine:asian"] ?? 0.0
    XCTAssertEqual(
      TasteResidualEngine.f6(contribution), 0.0, "a skip against no slate must not train")
  }

  func testCookWithoutExposureUsesFloor() {
    var engine = TasteResidualEngine(featureKeysByRecipe: ["r1": ["cuisine:asian"]])
    let cook = TasteEvent(
      id: "e1", at: "2026-01-01T00:00:00Z", kind: "recipe_cooked",
      recipe: TasteRecipeRef(id: "r1"), payload: ["rating": .number(5)])
    engine.ingest(events: [cook], exposures: [])

    let state = engine.finalState(evalAt: "2026-01-01T00:00:00Z")
    let posterior = state["cuisine:asian"]!
    XCTAssertEqual(posterior.alpha, 1.0 + Self.exposureFloor * 1.0, accuracy: 1e-9)
  }

  private static let exposureFloor = 0.15

  // MARK: GLOBAL_CLAMP

  func testLearnedSumIsClampedToGlobalClamp() {
    // Give one recipe many strongly-disliked features; the sum of
    // contributions is bounded by ±8 regardless.
    var features: [String: [String]] = [:]
    let disliked = (0..<30).map { "ingredient:\($0)" }
    features["r1"] = disliked
    var engine = TasteResidualEngine(featureKeysByRecipe: features)
    let events = (0..<30).map { i in
      TasteEvent(
        id: "e\(i)", at: "2026-01-0\(i % 9 + 1)T00:00:00Z", kind: "recipe_cooked",
        recipe: TasteRecipeRef(id: "r1"), payload: ["rating": .number(1)])
    }
    engine.ingest(events: events, exposures: [])
    let ranked = engine.rank(ruleScores: ["r1": 10.0], evalAt: "2026-02-01T00:00:00Z")
    XCTAssertEqual(ranked.count, 1)
    let totalLearned = ranked[0].totalScore - ranked[0].ruleScore
    XCTAssertEqual(totalLearned, -8.0, accuracy: 1e-9)
  }

  // MARK: Rated-cook merge (SPEC 9 transaction windows)

  func testLateRatingMergesIntoCookWindow() {
    var engine = TasteResidualEngine(featureKeysByRecipe: ["r1": ["cuisine:asian"]])
    let cook = TasteEvent(
      id: "c1", at: "2026-01-01T00:00:00Z", kind: "recipe_cooked",
      recipe: TasteRecipeRef(id: "r1"), payload: ["exposureId": .string("x1")])
    let rating = TasteEvent(
      id: "r1", at: "2026-01-01T00:00:00Z", kind: "recipe_rated",
      recipe: TasteRecipeRef(id: "r1"),
      payload: ["rating": .number(5), "cookEventId": .string("c1")])
    let exposure = TasteExposure(
      id: "x1", at: "2026-01-01T00:00:00Z", surface: "plan",
      slate: [TasteSlateItem(position: 0, recipe: TasteRecipeRef(id: "r1"))],
      feasible: [.string("r1"), .string("r2"), .string("r3"), .string("r4")])
    engine.ingest(events: [cook, rating], exposures: [exposure])

    // 5 stars: reward 1.0; share = max(1/4, 0.15) = 0.25. Cook, rating, and
    // evaluation share one instant so the merge arithmetic is asserted exactly
    // with no decay; the lazy-decay math is pinned by the golden-fixture
    // replay. The cook still sorts first: events tie on `at` and "c1" < "r1".
    let state = engine.finalState(evalAt: "2026-01-01T00:00:00Z")
    let posterior = state["cuisine:asian"]!
    // The rating adds on top of the no-rating update (0.25*0.3*(0.6, 0.4)) as
    // its own evidence (0.25*1.0*(1.0, 0.0)) — the contracts recompute model.
    let expectedAlpha = 1.0 + 0.25 * 0.3 * 0.6 + 0.25 * 1.0
    let expectedBeta = 1.0 + 0.25 * 0.3 * 0.4
    XCTAssertEqual(posterior.alpha, expectedAlpha, accuracy: 1e-9)
    XCTAssertEqual(posterior.beta, expectedBeta, accuracy: 1e-9)
  }

  // MARK: Feature extractor parity with the app semantics

  func testExtractorMatchesLabCatalogFeatures() throws {
    // The lab's committed fixture replay validated its own feature extraction
    // against this catalog; the Swift extractor must land on the same feature
    // key set shape: sorted, prefixed, non-empty for every fixture recipe.
    let catalog = try loadCatalogFeatures()
    XCTAssertFalse(catalog.featureKeysByRecipe.isEmpty)
    for (recipeId, keys) in catalog.featureKeysByRecipe {
      XCTAssertFalse(keys.isEmpty, "recipe \(recipeId) has no features")
      XCTAssertEqual(keys, keys.sorted(), "feature keys must be canonical-sorted for \(recipeId)")
      for key in keys {
        XCTAssertTrue(key.contains(":"), "malformed feature key \(key) for \(recipeId)")
      }
    }
    // Ingredient features use the ingredient id as the key suffix.
    let fixture = try TasteFixture.loadAll(fromDirectory: Self.fixturesDir).first!
    for entry in fixture.expectedRanking {
      for feature in entry.learnedFeatures {
        if feature.featureKey.hasPrefix("ingredient:") {
          let id = String(feature.featureKey.dropFirst("ingredient:".count))
          XCTAssertTrue(
            catalog.featureKeysByRecipe[entry.recipeId]?.contains(feature.featureKey) ?? false,
            "ingredient feature \(id) missing on \(entry.recipeId)")
        }
      }
    }
  }
}
