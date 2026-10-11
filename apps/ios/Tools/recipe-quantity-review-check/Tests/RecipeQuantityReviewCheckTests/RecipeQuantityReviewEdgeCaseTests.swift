import XCTest
import GRDB
@testable import RecipeQuantityReviewCheck

// MARK: - Calculator-level edge cases

/// Extreme but valid inputs: huge and tiny serving counts, substitute ratios far from 1
/// composed with extreme factors, all-optional / all-required row sets, unavailable
/// nutrition everywhere, and zero-gram rows. Every case asserts the designed behavior
/// with hand-computed expected values — none of them just executes code.
final class RecipeQuantityReviewEdgeCaseTests: XCTestCase {
  private func row(
    ingredientID: Int64 = 1,
    baseGrams: Double = 100,
    isRequired: Bool = true,
    ratio: Double? = nil,
    originalCalories: Double? = 400,
    replacementCalories: Double? = nil
  ) -> RecipeQuantityReviewSnapshot.Row {
    RecipeQuantityReviewSnapshot.Row(
      ingredientID: ingredientID,
      originalName: "Chicken",
      replacementName: ratio != nil ? "Tofu" : nil,
      isRequired: isRequired,
      baseOriginalGrams: baseGrams,
      substituteRatio: ratio,
      originalNutrition: originalCalories.map { QuantityReviewNutrition(calories: $0, protein: 0, carbs: 0, fat: 0) },
      replacementNutrition: replacementCalories.map { QuantityReviewNutrition(calories: $0, protein: 0, carbs: 0, fat: 0) })
  }

  private func joined(grams: Double, ratio: Double? = nil) -> QuantityReviewJoinedRow {
    QuantityReviewJoinedRow(
      ingredientID: 1, recipeID: 10, isRequired: true,
      quantityGrams: grams, displayName: "Chicken",
      substituteID: ratio != nil ? 2 : nil,
      substituteName: ratio != nil ? "Tofu" : nil,
      substituteRatio: ratio)
  }

  // 999 of 4 servings → factor 249.75. Amounts and calories must scale exactly once,
  // with no overflow, no drift, and no re-application of the factor.
  func testHugeServingsScaleAmountsAndCaloriesExactly() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 999, recipeServings: 4)
    XCTAssertEqual(factor, 249.75, accuracy: 0.0001)

    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 100, originalCalories: 400), servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 24975, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? -1, 99900, accuracy: 0.0001)

    // Two required rows: (400 + 300) kcal at base → 700 × 249.75.
    let rows = [
      row(ingredientID: 1, baseGrams: 100, originalCalories: 400),
      row(ingredientID: 2, baseGrams: 100, originalCalories: 300),
    ]
    let total = RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: factor)
    XCTAssertEqual(total ?? -1, 174825, accuracy: 0.0001)
  }

  // 0.5 of 4 servings is binary-exact (0.125); 0.5 of 3 is not (1/6). The tiny path must
  // stay accurate in both: amounts to four decimals, calories to well under a thousandth.
  func testTinyFractionalServingsKeepPrecision() throws {
    let exact = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: 4)
    XCTAssertEqual(exact, 0.125, accuracy: 0.0001)
    let exactAmounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 200, originalCalories: 400), servingFactor: exact)
    XCTAssertEqual(exactAmounts.originalGrams, 25, accuracy: 0.0001)
    XCTAssertEqual(exactAmounts.originalCalories ?? -1, 50, accuracy: 0.0001)

    let inexact = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: 3)
    XCTAssertEqual(inexact, 1.0 / 6.0, accuracy: 0.0001)
    let inexactAmounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 200, originalCalories: 330), servingFactor: inexact)
    XCTAssertEqual(inexactAmounts.originalGrams, 33.3333333, accuracy: 0.0001)
    // 330 × 1/6 = 55: the accumulated double error must stay far below the assertion.
    XCTAssertEqual(inexactAmounts.originalCalories ?? -1, 55, accuracy: 0.0001)
  }

  // Ratio ≫ 1 (3× more substitute than original) stacked on the huge factor 249.75 —
  // the ratio must land exactly once on the already-scaled amount, never compounded.
  func testHighSubstituteRatioComposedWithExtremeFactor() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 999, recipeServings: 4)
    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 100, ratio: 3.0, originalCalories: 400, replacementCalories: 300),
      servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 24975, accuracy: 0.0001)
    // 100 × 249.75 × 3 = 74925 (not 74925 × 3 again, not 24975 × 9).
    XCTAssertEqual(amounts.replacementGrams ?? -1, 74925, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? -1, 99900, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? -1, 74925, accuracy: 0.0001)

    // The substituted required total rides the replacement's calories.
    let total = RecipeQuantityReviewCalculator.requiredTotalCalories(
      rows: [row(baseGrams: 100, ratio: 3.0, originalCalories: 400, replacementCalories: 300)],
      servingFactor: factor)
    XCTAssertEqual(total ?? -1, 74925, accuracy: 0.0001)
  }

  // Ratio ≪ 1 (1%) stacked on the tiny factor 0.125: 200 g shrinks to a quarter gram.
  // Small doubles must stay finite and accurate — not underflow to zero silently
  // distinguishable from the real thing.
  func testLowSubstituteRatioComposedWithTinyFactor() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: 4)
    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 200, ratio: 0.01, originalCalories: 330, replacementCalories: 1.52),
      servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 25, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 0.25, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? -1, 41.25, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? -1, 0.19, accuracy: 0.0001)
  }

  // All rows optional: the required total is absent (nil — there is no required row to
  // sum), and the optional total is the real number, correct at 1× and at 249.75×.
  func testAllOptionalRowsRequiredTotalAbsentOptionalCorrect() throws {
    let rows = [
      row(ingredientID: 1, isRequired: false, originalCalories: 400),
      row(ingredientID: 2, isRequired: false, originalCalories: 500),
    ]
    XCTAssertNil(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1))
    XCTAssertNil(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 249.75))

    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 1) ?? -1,
      900, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 249.75) ?? -1,
      224775, accuracy: 0.0001)
  }

  // All rows required: the mirror image — optional total absent, required total real.
  func testAllRequiredRowsOptionalTotalAbsentRequiredCorrect() throws {
    let rows = [
      row(ingredientID: 1, isRequired: true, originalCalories: 400),
      row(ingredientID: 2, isRequired: true, originalCalories: 500),
    ]
    XCTAssertNil(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 1))
    XCTAssertNil(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 249.75))

    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1) ?? -1,
      900, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 249.75) ?? -1,
      224775, accuracy: 0.0001)
  }

  // Every row's nutrition is unavailable: both totals refuse with nil. Zero is not
  // "unavailable" — a zero-filled total would be a fabricated number.
  func testEveryRowUnavailableNutritionRefusesBothTotalsNoZeroFill() throws {
    let rows = [
      row(ingredientID: 1, isRequired: true, originalCalories: nil),
      row(ingredientID: 2, isRequired: true, originalCalories: nil),
      row(ingredientID: 3, isRequired: false, originalCalories: nil),
    ]
    for factor in [1.0, 3.0, 249.75] {
      XCTAssertNil(
        RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: factor),
        "required total must refuse at factor \(factor)")
      XCTAssertNil(
        RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: factor),
        "optional total must refuse at factor \(factor)")
    }
  }

  // Zero-gram rows: validation explicitly permits grams >= 0 (the schema check agrees),
  // so the designed behavior is acceptance — the row reads real (zero) nutrition,
  // contributes exactly zero, and does not poison the totals into nil.
  func testZeroGramRowIsValidAndContributesZero() throws {
    // Validation accepts what the schema permits: zero grams with no substitute.
    XCTAssertNoThrow(
      try RecipeQuantityReviewValidation.validateJoinedRows(
        recipeID: 10, rows: [joined(grams: 0)]))

    let zeroRow = row(ingredientID: 5, baseGrams: 0, originalCalories: 0)
    let zeroAmounts = RecipeQuantityReviewCalculator.amounts(row: zeroRow, servingFactor: 2)
    XCTAssertEqual(zeroAmounts.originalGrams, 0, accuracy: 0.0001)
    XCTAssertEqual(zeroAmounts.originalCalories ?? -1, 0, accuracy: 0.0001)

    // A real row plus the zero row: the required total stays the real row's number.
    let rows = [
      row(ingredientID: 1, baseGrams: 100, originalCalories: 400),
      zeroRow,
    ]
    let total = RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 2)
    XCTAssertEqual(total ?? -1, 800, accuracy: 0.0001)

    // And a zero-gram-only rowset totals 0.0 — a number, distinct from the nil refusal.
    let zeroOnly = RecipeQuantityReviewCalculator.requiredTotalCalories(
      rows: [zeroRow], servingFactor: 1)
    XCTAssertEqual(zeroOnly ?? -1, 0, accuracy: 0.0001)
  }
}

// MARK: - Session-level edge cases (real migrated database)

/// The same edge cases, end to end: session loads over the real schema and services,
/// then calculator scaling of the loaded snapshot. Expected values are hand-computed
/// from the seeded per-100 g stored energy values.
final class RecipeQuantityReviewEdgeCaseSessionTests: XCTestCase {
  // Synthetic nutrition catalog (per 100 g), mirroring the existing session tests.
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

  private func reader(
    _ db: DatabaseQueue, substitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)] = [:]
  ) throws -> ReaderAdapter {
    let (repository, nutritionService) = makeServices(db: db)
    return ReaderAdapter(
      recipeRepository: repository,
      nutritionService: nutritionService,
      activeSubstitutions: substitutions)
  }

  private func substitution(ratio: Double) -> Substitution {
    Substitution(originalId: 1, substituteId: 4, reasons: [], ratio: ratio, note: nil)
  }

  private func tofuIngredient(_ db: DatabaseQueue) throws -> Ingredient {
    let ingredient = try db.read { db in
      try Ingredient.fetchOne(db, id: Int64(4))
    }
    return try XCTUnwrap(ingredient)
  }

  /// Recipe 20 serves 7 (off every option): chicken 200 g + rice 100 g required,
  /// broccoli 50 g optional.
  private func seedOffOption(_ db: DatabaseQueue) throws {
    try ReviewFixture.seed(
      db,
      recipes: [ReviewFixture.SeedRecipe(20, "Feast for seven", 7)],
      ingredients: [chicken, rice, broccoli, tofu],
      rows: [
        ReviewFixture.SeedRow(20, 1, true, 200, "200 g"),
        ReviewFixture.SeedRow(20, 2, true, 100, "100 g"),
        ReviewFixture.SeedRow(20, 3, false, 50, "50 g"),
      ])
  }

  /// Recipes 21 (serves 4) and 22 (serves 3) with the same row shapes.
  private func seedServingVariants(_ db: DatabaseQueue) throws {
    try ReviewFixture.seed(
      db,
      recipes: [
        ReviewFixture.SeedRecipe(21, "Quadruple", 4),
        ReviewFixture.SeedRecipe(22, "Triple", 3),
      ],
      ingredients: [chicken, rice, broccoli, tofu],
      rows: [
        ReviewFixture.SeedRow(21, 1, true, 200, "200 g"),
        ReviewFixture.SeedRow(21, 2, true, 100, "100 g"),
        ReviewFixture.SeedRow(21, 3, false, 50, "50 g"),
        ReviewFixture.SeedRow(22, 1, true, 200, "200 g"),
      ])
  }

  /// Recipe 23 (serves 4): chicken 200 g with the given substitute ratio attached.
  private func seedSwapped(_ db: DatabaseQueue, recipeID: Int64, ratio: Double) throws {
    try ReviewFixture.seed(
      db,
      recipes: [ReviewFixture.SeedRecipe(recipeID, "Swapped", 4)],
      ingredients: [chicken, rice, broccoli, tofu],
      rows: [
        ReviewFixture.SeedRow(recipeID, 1, true, 200, "200 g"),
      ])
  }

  // A recipe serving count off every option: the default lands on the closest option
  // below (7 → 6), and the composed amounts match hand computation at 6/7 exactly.
  func testDefaultServingsForOffOptionRecipeComposeEndToEnd() async throws {
    let db = try ReviewFixture.inMemory()
    try seedOffOption(db)

    let defaultServings = RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 7)
    XCTAssertEqual(defaultServings, 6)

    let snapshot = try await RecipeQuantityReviewSession(read: try reader(db)).load(recipeID: 20)
    XCTAssertEqual(snapshot.recipeServings, 7)

    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: try XCTUnwrap(defaultServings), recipeServings: snapshot.recipeServings)
    XCTAssertEqual(factor, 6.0 / 7.0, accuracy: 0.0001)

    let chickenRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: chickenRow, servingFactor: factor)
    // 200 g × 6/7 = 1200/7 g; 330 kcal × 6/7 = 1980/7 kcal.
    XCTAssertEqual(amounts.originalGrams, 171.4285714, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? -1, 282.8571429, accuracy: 0.001)

    // Required total: (330 + 130) × 6/7 = 2760/7. Optional: 17 × 6/7 = 102/7.
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      394.2857143, accuracy: 0.001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      14.5714286, accuracy: 0.001)
  }

  // 999 servings of a 4-serving recipe, end to end through the real database: amounts
  // reach ~50 kg and calories reach ~10^5 without drift, and the totals add up exactly.
  func testHugeServingsEndToEndThroughRealDatabase() async throws {
    let db = try ReviewFixture.inMemory()
    try seedServingVariants(db)

    let snapshot = try await RecipeQuantityReviewSession(read: try reader(db)).load(recipeID: 21)
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 999, recipeServings: snapshot.recipeServings)

    let chickenRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let chickenAmounts = RecipeQuantityReviewCalculator.amounts(row: chickenRow, servingFactor: factor)
    XCTAssertEqual(chickenAmounts.originalGrams, 49950, accuracy: 0.0001)
    XCTAssertEqual(chickenAmounts.originalCalories ?? -1, 82417.5, accuracy: 0.0001)

    // Required total: (330 + 130) × 249.75 = 114885. Optional: 17 × 249.75 = 4245.75.
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      114885, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      4245.75, accuracy: 0.0001)
  }

  // 0.5 servings, end to end: the binary-exact path (of 4) and the inexact path
  // (of 3, factor 1/6) both land on hand-computed values.
  func testTinyFractionalServingsEndToEnd() async throws {
    let db = try ReviewFixture.inMemory()
    try seedServingVariants(db)

    let reader = try self.reader(db)
    let snapshot4 = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 21)
    let factor4 = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: snapshot4.recipeServings)
    let chicken4 = try XCTUnwrap(
      snapshot4.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let amounts4 = RecipeQuantityReviewCalculator.amounts(row: chicken4, servingFactor: factor4)
    XCTAssertEqual(amounts4.originalGrams, 25, accuracy: 0.0001)
    XCTAssertEqual(amounts4.originalCalories ?? -1, 41.25, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot4.rows, servingFactor: factor4) ?? -1,
      57.5, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: snapshot4.rows, servingFactor: factor4) ?? -1,
      2.125, accuracy: 0.0001)

    let snapshot3 = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 22)
    let factor3 = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: snapshot3.recipeServings)
    let chicken3 = try XCTUnwrap(
      snapshot3.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let amounts3 = RecipeQuantityReviewCalculator.amounts(row: chicken3, servingFactor: factor3)
    // 200 g × 1/6 and 330 kcal × 1/6 = 55 — inexact factors must not drift the energy.
    XCTAssertEqual(amounts3.originalGrams, 33.3333333, accuracy: 0.0001)
    XCTAssertEqual(amounts3.originalCalories ?? -1, 55, accuracy: 0.0001)
  }

  // A 3× substitute ratio (≫ 1) end to end: the substitute's nutrition is read at
  // 600 g (stored 456 kcal), and the huge factor scales it exactly once.
  func testHighSubstituteRatioEndToEndThroughRealDatabase() async throws {
    let db = try ReviewFixture.inMemory()
    try seedSwapped(db, recipeID: 23, ratio: 3.0)

    let reader = try self.reader(db, substitutions: [1: (substitution(ratio: 3.0), try tofuIngredient(db))])
    let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 23)

    let chickenRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    // Stored replacement nutrition: 76 kcal/100 g at 200 × 3 = 600 g → 456 kcal.
    XCTAssertEqual(chickenRow.replacementNutrition?.calories ?? -1, 456, accuracy: 0.0001)

    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 999, recipeServings: snapshot.recipeServings)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: chickenRow, servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 49950, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 149850, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? -1, 113886, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      113886, accuracy: 0.0001)
  }

  // A 1% substitute ratio (≪ 1) end to end: the read happens at 2 g (stored 1.52 kcal)
  // and the tiny factor shrinks the plan amount to a quarter gram.
  func testLowSubstituteRatioEndToEndThroughRealDatabase() async throws {
    let db = try ReviewFixture.inMemory()
    try seedSwapped(db, recipeID: 24, ratio: 0.01)

    let reader = try self.reader(db, substitutions: [1: (substitution(ratio: 0.01), try tofuIngredient(db))])
    let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 24)

    let chickenRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    XCTAssertEqual(chickenRow.replacementNutrition?.calories ?? -1, 1.52, accuracy: 0.0001)

    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: snapshot.recipeServings)
    let amounts = RecipeQuantityReviewCalculator.amounts(row: chickenRow, servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 25, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 0.25, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? -1, 0.19, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      0.19, accuracy: 0.0001)
  }

  // Two consecutive loads reviewed at different serving choices: the second load must be
  // an identical fresh snapshot, its amounts must derive only from (snapshot, factor) —
  // never from the first load's scaled values — and the first snapshot's bases stay put.
  func testConsecutiveLoadsWithDifferentServingChoicesDoNotLeak() async throws {
    let db = try ReviewFixture.inMemory()
    try seedSwapped(db, recipeID: 25, ratio: 0.8)
    try ReviewFixture.seed(
      db,
      recipes: [],
      ingredients: [],
      rows: [
        ReviewFixture.SeedRow(25, 2, true, 100, "100 g"),
        ReviewFixture.SeedRow(25, 3, false, 50, "50 g"),
      ])

    let reader = try self.reader(db, substitutions: [1: (substitution(ratio: 0.8), try tofuIngredient(db))])
    let first = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 25)

    // Review the first snapshot at 12 servings (factor 3) before loading again.
    let factorBig = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 12, recipeServings: first.recipeServings)
    let firstRow = try XCTUnwrap(
      first.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let bigAmounts = RecipeQuantityReviewCalculator.amounts(row: firstRow, servingFactor: factorBig)
    XCTAssertEqual(bigAmounts.replacementGrams ?? -1, 480, accuracy: 0.0001)
    XCTAssertEqual(bigAmounts.replacementCalories ?? -1, 364.8, accuracy: 0.0001)

    // Second load, reviewed at 0.5 servings (factor 0.125).
    let second = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 25)
    XCTAssertEqual(second, first, "a fresh load must reproduce the same snapshot")

    let factorSmall = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 0.5, recipeServings: second.recipeServings)
    let secondRow = try XCTUnwrap(
      second.rows.first { $0.ingredientID == 1 } as RecipeQuantityReviewSnapshot.Row?)
    let smallFromSecond = RecipeQuantityReviewCalculator.amounts(row: secondRow, servingFactor: factorSmall)
    XCTAssertEqual(smallFromSecond.replacementGrams ?? -1, 20, accuracy: 0.0001)
    XCTAssertEqual(smallFromSecond.replacementCalories ?? -1, 15.2, accuracy: 0.0001)

    // The same factor on the first snapshot produces identical amounts: no load history.
    let smallFromFirst = RecipeQuantityReviewCalculator.amounts(row: firstRow, servingFactor: factorSmall)
    XCTAssertEqual(smallFromFirst, smallFromSecond)

    // Totals at the small factor derive from the second snapshot alone.
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: second.rows, servingFactor: factorSmall) ?? -1,
      31.45, accuracy: 0.0001)
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: second.rows, servingFactor: factorSmall) ?? -1,
      2.125, accuracy: 0.0001)

    // And the first snapshot's base is untouched by all the scaling above.
    XCTAssertEqual(firstRow.baseOriginalGrams, 200, accuracy: 0.0001)
  }

  // Every ingredient's nutrition read fails, end to end: the load still succeeds, but
  // every row carries nil nutrition (unavailable, never zero-filled) and both totals
  // refuse. The reference read is a different path and stays intact.
  func testEveryIngredientUnavailableNutritionEndToEnd() async throws {
    let db = try ReviewFixture.inMemory()
    try seedSwapped(db, recipeID: 26, ratio: 0.8)
    try ReviewFixture.seed(
      db,
      recipes: [],
      ingredients: [],
      rows: [
        ReviewFixture.SeedRow(26, 2, true, 100, "100 g"),
        ReviewFixture.SeedRow(26, 3, false, 50, "50 g"),
      ])

    let failingNutrition = NutritionFailingReader(
      base: try reader(db, substitutions: [1: (substitution(ratio: 0.8), try tofuIngredient(db))]))
    let snapshot = try await RecipeQuantityReviewSession(read: failingNutrition).load(recipeID: 26)

    XCTAssertEqual(snapshot.rows.count, 3)
    for row in snapshot.rows {
      XCTAssertNil(row.originalNutrition, "row \(row.ingredientID) must be unavailable, not zero")
      XCTAssertNil(row.replacementNutrition, "row \(row.ingredientID) substitute must be unavailable, not zero")
    }

    for factor in [1.0, 3.0, 249.75] {
      XCTAssertNil(
        RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor),
        "required total must refuse at factor \(factor)")
      XCTAssertNil(
        RecipeQuantityReviewCalculator.optionalTotalCalories(rows: snapshot.rows, servingFactor: factor),
        "optional total must refuse at factor \(factor)")
    }

    // Only the per-row nutrition path degraded; the reference is a separate read.
    let reference = try XCTUnwrap(snapshot.referenceCaloriesPerServing as Double?)
    XCTAssertEqual(reference, 115, accuracy: 0.001) // (165×2 + 130×1) / 4
  }

  // Zero-gram rows through the real schema (which, like validation, permits grams >= 0):
  // the read succeeds with a genuine 0.0, the row scales to 0, and the totals stay real
  // numbers — the optional total is 0.0, not nil, because the nutrition is present.
  func testZeroGramRowEndToEndThroughRealDatabase() async throws {
    let db = try ReviewFixture.inMemory()
    try ReviewFixture.seed(
      db,
      recipes: [ReviewFixture.SeedRecipe(27, "Light", 2)],
      ingredients: [chicken, rice, broccoli, tofu],
      rows: [
        ReviewFixture.SeedRow(27, 1, true, 100, "100 g"),
        ReviewFixture.SeedRow(27, 3, false, 0, "0 g"),
      ])

    let snapshot = try await RecipeQuantityReviewSession(read: try reader(db)).load(recipeID: 27)

    let zeroRow = try XCTUnwrap(
      snapshot.rows.first { $0.ingredientID == 3 } as RecipeQuantityReviewSnapshot.Row?)
    XCTAssertEqual(zeroRow.baseOriginalGrams, 0, accuracy: 0.0001)
    // A real read at 0 g: genuine zero, finite — not a failed read, not NaN.
    let zeroCalories = try XCTUnwrap(zeroRow.originalNutrition?.calories)
    XCTAssertEqual(zeroCalories, 0, accuracy: 0.0001)
    XCTAssertFalse(zeroCalories.isNaN)

    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 4, recipeServings: snapshot.recipeServings)
    let zeroAmounts = RecipeQuantityReviewCalculator.amounts(row: zeroRow, servingFactor: factor)
    XCTAssertEqual(zeroAmounts.originalGrams, 0, accuracy: 0.0001)
    XCTAssertEqual(zeroAmounts.originalCalories ?? -1, 0, accuracy: 0.0001)

    // Required total is the real row only (165 × 2 = 330); the zero-gram optional row
    // totals 0.0 — a number, distinct from the nil refusal.
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: snapshot.rows, servingFactor: factor) ?? -1,
      330, accuracy: 0.0001)
    let optional = RecipeQuantityReviewCalculator.optionalTotalCalories(rows: snapshot.rows, servingFactor: factor)
    XCTAssertNotNil(optional)
    XCTAssertEqual(optional ?? -1, 0, accuracy: 0.0001)
  }
}

/// Wraps a reader and fails only the per-ingredient nutrition read — everything else
/// delegates, so the load succeeds while every row's nutrition is unavailable.
private struct NutritionFailingReader: RecipeQuantityReviewReading {
  let base: ReaderAdapter

  func fetchRecipeServings(id: Int64) throws -> Int? {
    try base.fetchRecipeServings(id: id)
  }
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    try base.joinedRows(recipeID: recipeID)
  }
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    struct Unavailable: Error {}
    throw Unavailable()
  }
  func referencePerServingCalories(recipeID: Int64) throws -> Double? {
    try base.referencePerServingCalories(recipeID: recipeID)
  }
}
