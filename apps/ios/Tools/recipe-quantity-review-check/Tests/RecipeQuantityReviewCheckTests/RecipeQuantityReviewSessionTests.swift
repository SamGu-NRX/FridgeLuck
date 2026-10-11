import XCTest
import GRDB
@testable import RecipeQuantityReviewCheck

/// End-to-end session loads over the real migrated schema and services, the stale-load
/// discipline, and proof that the review writes nothing.
final class RecipeQuantityReviewSessionTests: XCTestCase {
  // Synthetic nutrition catalog (per 100 g). Chicken's stored calories are deliberately
  // inconsistent with 4/4/9 on its macros in the divergence test.
  private let chicken = ReviewFixture.SeedIngredient(1, "chicken breast", 165, 31, 0, 3.6)
  private let rice = ReviewFixture.SeedIngredient(2, "jasmine rice", 130, 2.7, 28, 0.3)
  private let broccoli = ReviewFixture.SeedIngredient(3, "broccoli", 34, 2.8, 7, 0.4)
  private let tofu = ReviewFixture.SeedIngredient(4, "tofu", 76, 8, 1.9, 4.8)

  private func makeServices(db: DatabaseQueue) -> (RecipeRepository, NutritionService) {
    let nutritionService = NutritionService(db: db)
    let personalizationService = PersonalizationService(db: db)
    let healthScoringService = HealthScoringService(
      nutritionService: nutritionService, db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoringService,
      personalizationService: personalizationService)
    return (repository, nutritionService)
  }

  private func standardFixture(_ db: DatabaseQueue) throws {
    try ReviewFixture.seed(
      db,
      recipes: [ReviewFixture.SeedRecipe(10, "Chicken and rice", 4)],
      ingredients: [chicken, rice, broccoli, tofu],
      rows: [
        ReviewFixture.SeedRow(10, 1, true, 200, "200 g"),
        ReviewFixture.SeedRow(10, 2, true, 100, "100 g"),
        ReviewFixture.SeedRow(10, 3, false, 50, "50 g"),
      ])
  }

  private func substitutionFor(_ db: DatabaseQueue) throws -> (substitution: Substitution, ingredient: Ingredient) {
    // The drawer passes the plan's selected swaps; the test builds one from the catalog
    // row itself so the mapping stays real.
    let ingredient = try db.read { db in
      try Ingredient.fetchOne(db, id: Int64(4))
    }
    guard let ingredient else { throw CancellationError() }
    let substitution = Substitution(
      originalId: 1, substituteId: 4, reasons: [], ratio: 0.8, note: nil)
    return (substitution, ingredient)
  }

  func testSessionLoadsSnapshotFromRealMigratedDatabase() async throws {
    let db = try ReviewFixture.inMemory()
    try standardFixture(db)
    let (repository, nutritionService) = makeServices(db: db)

    let reader = ReaderAdapter(
      recipeRepository: repository,
      nutritionService: nutritionService,
      activeSubstitutions: [1: try substitutionFor(db)])
    let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 10)

    // Identity and denominator.
    XCTAssertEqual(snapshot.recipeID, 10)
    XCTAssertEqual(snapshot.recipeServings, 4)

    // Reference (NutritionService.macros, swaps: []): required rows only —
    // (165×2 + 130×1) / 4 = 115.0 kcal, stored energy.
    let reference = try XCTUnwrap(
      snapshot.referenceCaloriesPerServing as Double?)
    XCTAssertEqual(reference, 115, accuracy: 0.001)

    // Three rows, required ones first (the repository orders by is_required DESC).
    XCTAssertEqual(snapshot.rows.count, 3)
    XCTAssertEqual(snapshot.rows.map(\.ingredientID), [1, 2, 3])
    XCTAssertEqual(snapshot.rows.map(\.isRequired), [true, true, false])

    // The substituted row carries the fresh read's name and ratio.
    XCTAssertEqual(snapshot.rows[0].replacementName, "Tofu")
    XCTAssertEqual(snapshot.rows[0].substituteRatio ?? 0, 0.8, accuracy: 0.0001)

    // Nutrition at base grams, from stored energy: chicken at 200 g → 330 kcal,
    // tofu (the substitute) at 200 × 0.8 = 160 g → 121.6 kcal.
    XCTAssertEqual(snapshot.rows[0].originalNutrition?.calories ?? 0, 330, accuracy: 0.001)
    XCTAssertEqual(snapshot.rows[0].replacementNutrition?.calories ?? 0, 121.6, accuracy: 0.001)
    XCTAssertEqual(snapshot.rows[1].originalNutrition?.calories ?? 0, 130, accuracy: 0.001)

    // Scaling the snapshot with a fractional selection: 2.5 of 4 → factor 0.625.
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 2.5, recipeServings: snapshot.recipeServings)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: snapshot.rows[0], servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 125, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 100, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? 0, 76, accuracy: 0.001) // 121.6 × 0.625
  }

  func testRecipeNotFoundRefuses() async {
    let db = try! ReviewFixture.inMemory()
    try! standardFixture(db)
    let (repository, nutritionService) = makeServices(db: db)

    // Recipe 10 has rows; recipe 99 has none — the joinedRows read returns empty first.
    let reader = ReaderAdapter(
      recipeRepository: repository, nutritionService: nutritionService,
      activeSubstitutions: [:])
    do {
      _ = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 99)
      XCTFail("expected recipeNotFound")
    } catch let failure as RecipeQuantityReviewFailure {
      XCTAssertEqual(failure, .noIngredientRows)
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testReadFailureSurfacesAsReadFailed() async {
    let session = RecipeQuantityReviewSession(read: FailingReader())
    do {
      _ = try await session.load(recipeID: 10)
      XCTFail("expected readFailed")
    } catch let failure as RecipeQuantityReviewFailure {
      guard case .readFailed = failure else {
        return XCTFail("expected readFailed, got \(failure)")
      }
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testReferenceReadFailureDegradesToNilNotZero() async throws {
    let db = try ReviewFixture.inMemory()
    try standardFixture(db)
    let (repository, nutritionService) = makeServices(db: db)

    let failingReference = ReferenceFailingReader(
      base: ReaderAdapter(
        recipeRepository: repository, nutritionService: nutritionService,
        activeSubstitutions: [:]))
    let snapshot = try await RecipeQuantityReviewSession(read: failingReference).load(recipeID: 10)
    XCTAssertNil(snapshot.referenceCaloriesPerServing)
    // The rows are still real; only the reference degraded.
    XCTAssertEqual(snapshot.rows.count, 3)
  }

  func testCancelledLoadNeverReturnsSnapshot() async throws {
    let reader = GatedReader()
    let session = RecipeQuantityReviewSession(read: reader)

    let loadStarted = expectation(description: "joinedRows entered")
    let task = Task {
      try await session.load(recipeID: 10)
    }

    // Wait for the first read to be in flight, cancel mid-sequence, then release the gate.
    Task.detached {
      _ = reader.joinedEntered.wait(timeout: .now() + 5)
      loadStarted.fulfill()
    }
    await fulfillment(of: [loadStarted], timeout: 10)
    task.cancel()
    reader.releaseJoined.signal()

    do {
      let snapshot = try await task.value
      XCTFail("a cancelled load returned a snapshot: \(snapshot)")
    } catch {
      // Cancellation is expected. The decisive assertion: the sequence never advanced past
      // the first read, so no snapshot could be committed from a stale load.
      XCTAssertEqual(reader.joinedCalls, 1)
      XCTAssertEqual(reader.servingCalls, 0)
    }
  }

  func testReviewFlowWritesNothingAcrossEveryServingOption() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-nowrite-\(UUID().uuidString).sqlite")
      .path
    let db = try ReviewFixture.onDisk(at: path)
    try standardFixture(db)
    let (repository, nutritionService) = makeServices(db: db)

    let before = try ReviewFixture.contentDump(path)

    // The full read-only flow: load, then scale every row at every finite serving option.
    let reader = ReaderAdapter(
      recipeRepository: repository,
      nutritionService: nutritionService,
      activeSubstitutions: [1: try substitutionFor(db)])
    let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 10)
    for servings in RecipeQuantityReviewCalculator.servingOptions {
      let factor = try RecipeQuantityReviewCalculator.servingFactor(
        selectedServings: servings, recipeServings: snapshot.recipeServings)
      for row in snapshot.rows {
        _ = RecipeQuantityReviewCalculator.amounts(row: row, servingFactor: factor)
      }
      _ = RecipeQuantityReviewCalculator.requiredTotalCalories(
        rows: snapshot.rows, servingFactor: factor)
      _ = RecipeQuantityReviewCalculator.optionalTotalCalories(
        rows: snapshot.rows, servingFactor: factor)
    }

    let after = try ReviewFixture.contentDump(path)
    XCTAssertEqual(before, after, "the review flow modified the database")
  }

  func testFractionalServingsOnRealDataMatchHandComputation() async throws {
    let db = try ReviewFixture.inMemory()
    try standardFixture(db)
    let (repository, nutritionService) = makeServices(db: db)

    let reader = ReaderAdapter(
      recipeRepository: repository, nutritionService: nutritionService,
      activeSubstitutions: [:])
    let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 10)

    // 2.5 of 4 servings: chicken 200 g → 125 g → 206.25 kcal (stored 165/100 g).
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 2.5, recipeServings: snapshot.recipeServings)
    let chickenRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: chickenRow, servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 125, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? 0, 206.25, accuracy: 0.001)
  }
}

/// Wraps a reader and fails only the reference read — everything else delegates.
private struct ReferenceFailingReader: RecipeQuantityReviewReading {
  let base: ReaderAdapter

  func fetchRecipeServings(id: Int64) throws -> Int? {
    try base.fetchRecipeServings(id: id)
  }
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    try base.joinedRows(recipeID: recipeID)
  }
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    try base.nutrition(ingredientID: ingredientID, grams: grams)
  }
  func referencePerServingCalories(recipeID: Int64) throws -> Double? {
    struct No: Error {}
    throw No()
  }
}
