import XCTest
@testable import WeeklyPlanCore

/// Core allocator/engine/oracle behavior on hand-built states, plus
/// fingerprint stability. These are exact, not statistical.
final class PlannerCoreTests: XCTestCase {

  private func recipe(
    _ id: Int64, title: String = "R", time: Int = 30, diet: String? = nil,
    _ needs: [WeeklyPlanNeed]
  ) -> WeeklyPlanRecipe {
    WeeklyPlanRecipe(id: id, title: title, timeMinutes: time, dietClass: diet, needs: needs)
  }

  private func need(_ id: Int64, _ grams: Double, optional: Bool = false, subs: [Int64] = []) -> WeeklyPlanNeed {
    WeeklyPlanNeed(ingredientId: id, gramsPerServing: grams, isOptional: optional, substitutes: subs)
  }

  private func stock(_ id: Int64, _ grams: Double?, known: Bool = true) -> WeeklyPlanStockItem {
    WeeklyPlanStockItem(ingredientId: id, availableGrams: grams ?? 0, quantityIsKnown: known)
  }

  private func input(
    recipes: [WeeklyPlanRecipe], slots: [Int64], stock: [WeeklyPlanStockItem],
    excluded: [Int64] = [], diet: String? = nil, maxTime: Int? = nil,
    maxRepeats: Int = 1, servings: Int = 2, urgency: [Int64: Double] = [:]
  ) -> WeeklyPlanInput {
    WeeklyPlanInput(
      slots: slots.map { WeeklyPlanSlot(id: $0, label: "Slot \($0)") },
      recipes: recipes, stock: stock,
      urgencies: urgency.map { WeeklyPlanUrgency(ingredientId: $0.key, weightPerGram: $0.value) },
      constraints: WeeklyPlanConstraints(
        excludedIngredientIds: Set(excluded), requiredDietClass: diet,
        maxCookTimeMinutes: maxTime, servingsPerMeal: servings, maxRepeatsPerRecipe: maxRepeats))
  }

  // MARK: allocator semantics

  func testAmpleStockIsFeasibleWithNoShortages() {
    let input = input(
      recipes: [recipe(1, [need(100, 200)])],
      slots: [10],
      stock: [stock(100, 1_000)])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertTrue(result.shortages.isEmpty)
    XCTAssertEqual(result.assignments.first?.recipeId, 1)
  }

  func testOptionalShortfallIsReportedButPlanStaysFeasible() {
    // A required shortfall is fatal; an optional one is only reported.
    let input = input(
      recipes: [recipe(1, [need(100, 500, optional: true)])],
      slots: [10],
      stock: [stock(100, 100)])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(result.shortages.count, 1)
    XCTAssertEqual(result.shortages.first?.ingredientId, 100)
    XCTAssertEqual(result.shortages.first?.shortfallGrams ?? 0, 900, accuracy: 1e-9)
  }

  func testUnknownQuantityMakesRequiredPlanInfeasible() {
    let input = input(
      recipes: [recipe(1, [need(100, 100)])],
      slots: [10],
      stock: [stock(100, nil, known: false)])
    let result = WeeklyPlanEngine.plan(input)
    guard case .infeasible(let violations) = result.verdict else {
      return XCTFail("expected infeasible")
    }
    XCTAssertTrue(violations.contains { $0 == .unknownAmountCannotCover(ingredientId: 100) })
  }

  func testOptionalNeedWithUnknownQuantityIsDroppedNotInfeasible() {
    let input = input(
      recipes: [recipe(1, [need(100, 100, optional: true)])],
      slots: [10],
      stock: [stock(100, nil, known: false)])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    // Reported as an unconfirmed-amount shortage, never fatal.
    XCTAssertEqual(result.shortages.count, 1)
    XCTAssertEqual(result.shortages.first?.category, .unknownAmount)
  }

  func testSubstitutionResolvesShortage() {
    // Primary 100 has only 50g; substitute 101 has plenty. The allocation
    // resolves the required need through the substitute and reports it.
    let input = input(
      recipes: [recipe(1, [need(100, 200, subs: [101])])],
      slots: [10],
      stock: [stock(100, 50), stock(101, 1_000)])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(result.assignments.first?.substitutions.count, 1)
    XCTAssertEqual(result.assignments.first?.substitutions.first?.plannedIngredientId, 100)
    XCTAssertEqual(result.assignments.first?.substitutions.first?.substituteIngredientId, 101)
  }

  func testExcludedPrimaryAndSubstituteMakePlanInfeasible() {
    let input = input(
      recipes: [recipe(1, [need(100, 100, subs: [101])])],
      slots: [10],
      stock: [stock(100, 1_000), stock(101, 1_000)],
      excluded: [100, 101])
    let result = WeeklyPlanEngine.plan(input)
    guard case .infeasible(let violations) = result.verdict else {
      return XCTFail("expected infeasible — exclusions are never waived")
    }
    XCTAssertTrue(
      violations.contains {
        if case .excludedIngredientRequired(let recipeId, let ingredientId) = $0 {
          return recipeId == 1 && ingredientId == 100
        }
        return false
      })
  }

  func testExcludedOptionalNeedIsOmitted() {
    let input = input(
      recipes: [recipe(1, [need(100, 100, optional: true)])],
      slots: [10],
      stock: [stock(100, 1_000)],
      excluded: [100])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertTrue(result.shortages.isEmpty)
  }

  // MARK: eligibility

  func testDietClassAndTimeCeilingsFilterEligibility() {
    let input = input(
      recipes: [
        recipe(1, time: 90, diet: "vegan", [need(100, 100)]),
        recipe(2, time: 20, diet: "keto", [need(100, 100)]),
      ],
      slots: [10],
      stock: [stock(100, 1_000)],
      diet: "vegan",
      maxTime: 30)
    let result = WeeklyPlanEngine.plan(input)
    guard case .infeasible = result.verdict else {
      return XCTFail("both recipes must be ineligible: wrong diet or too slow")
    }
  }

  func testMaxRepeatsForcesVarietyAcrossSlots() {
    let input = input(
      recipes: [
        recipe(1, [need(100, 100)]),
        recipe(2, [need(100, 100)]),
      ],
      slots: [10, 11],
      stock: [stock(100, 5_000)],
      maxRepeats: 1)
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    let recipeIds = result.assignments.map(\.recipeId)
    XCTAssertEqual(Set(recipeIds).count, 2, "one repeat is allowed, two are not")
  }

  // MARK: scoring direction

  func testUseSoonerRecipesWinUnderUrgency() {
    // Both recipes are otherwise identical; the one using the urgent
    // ingredient must be chosen because urgency pulls consumption forward.
    let plain = recipe(1, [need(100, 200)])
    let urgent = recipe(2, [need(101, 200)])
    let input = input(
      recipes: [plain, urgent],
      slots: [10],
      stock: [stock(100, 1_000), stock(101, 1_000)],
      urgency: [101: 0.01])
    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(result.assignments.first?.recipeId, 2)
  }

  // MARK: fingerprints

  func testFingerprintIgnoresStockOrderingButReflectsConstraints() {
    let recipeA = recipe(1, [need(100, 100)])
    let a = input(
      recipes: [recipeA], slots: [10], stock: [stock(100, 500), stock(101, 50)])
    let reordered = input(
      recipes: [recipeA], slots: [10], stock: [stock(101, 50), stock(100, 500)])
    XCTAssertEqual(WeeklyPlanFingerprint.compute(a), WeeklyPlanFingerprint.compute(reordered))

    var withExclusion = a
    withExclusion.constraints.excludedIngredientIds = [100]
    XCTAssertNotEqual(WeeklyPlanFingerprint.compute(a), WeeklyPlanFingerprint.compute(withExclusion))

    var withServings = a
    withServings.constraints.servingsPerMeal = 4
    XCTAssertNotEqual(WeeklyPlanFingerprint.compute(a), WeeklyPlanFingerprint.compute(withServings))
  }
}
