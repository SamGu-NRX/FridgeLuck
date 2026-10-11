import XCTest
@testable import WeeklyPlanCore

/// Hand-computed allocation controls.
///
/// The oracle sweep proves the engine agrees with the reference search, but
/// both share the allocator, scorer, and comparison — agreement cannot catch a
/// defect in what they share. These cases are worked out by hand instead: the
/// expected rows, grams, shortfalls, grouped shortages, and objective scores
/// below are computed on paper from the documented semantics, then asserted
/// exactly. If the canonical arithmetic changes, these are the tests that must
/// be consciously re-derived, not re-run.
final class HandComputedAllocationTests: XCTestCase {

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

  private func slot(_ id: Int64) -> WeeklyPlanSlot {
    WeeklyPlanSlot(id: id, label: "Slot \(id)")
  }

  private func input(
    recipes: [WeeklyPlanRecipe], slots: [Int64], stock: [WeeklyPlanStockItem],
    excluded: [Int64] = [], maxRepeats: Int = 1, servings: Int = 2,
    urgency: [Int64: Double] = [:]
  ) -> WeeklyPlanInput {
    WeeklyPlanInput(
      slots: slots.map(slot), recipes: recipes, stock: stock,
      urgencies: urgency.map { WeeklyPlanUrgency(ingredientId: $0.key, weightPerGram: $0.value) },
      constraints: WeeklyPlanConstraints(
        excludedIngredientIds: Set(excluded), requiredDietClass: nil,
        maxCookTimeMinutes: nil, servingsPerMeal: servings, maxRepeatsPerRecipe: maxRepeats))
  }

  // MARK: Case 1 — single slot, ample stock, hand-scored

  func testSingleSlotExactRowAndScore() {
    // Recipe 7 needs 150 g/serving of 300; servings 2 → 300 g total.
    // Stock: 500 g of 300 → covers, one row, nothing else.
    // Score: urgency 300 = 0.01 pts/g → 0.01 × 300 = 3 use-soon points;
    // time 30 min × 0.05 = 1.5; no repetition → 3 − 1.5 = 1.5.
    let r = recipe(7, time: 30, [need(300, 150)])
    let input = input(
      recipes: [r], slots: [10], stock: [stock(300, 500)], urgency: [300: 0.01])

    let rows = WeeklyPlanConsumption.allocate(
      assignment: [(slot(10), r)], stock: input.stockByID, constraints: input.constraints)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(
      rows[0],
      WeeklyPlanConsumptionRow(
        slotId: 10, recipeId: 7, ingredientId: 300, isRequired: true,
        grams: 300, resolvedIngredientId: 300, substituted: false,
        shortfallGrams: 0, unresolvableExcluded: false))

    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertTrue(result.shortages.isEmpty)
    XCTAssertEqual(result.score, 1.5, accuracy: 1e-9)
  }

  // MARK: Case 2 — substitution drains the substitute across slots

  func testSubstituteDrainsAcrossSlotsHandWorked() {
    // Recipe 7 needs 100 g/serving of 200, substitute 201; servings 2 → 200 g
    // per slot. Stock: 200 has 100 g, 201 has 300 g. maxRepeats 2, two slots.
    //
    // Slot 10: 200 (100 g) does not cover 200; 201 (300 g) does → plan 201,
    // consume 200, 201 left with 100. Row: substituted, shortfall 0.
    // Slot 11: 201 has 100 < 200 → no candidate covers → fall back to
    // allowed[0] = 200 (known, 100 g) → take 100, shortfall 100.
    // Required shortfall is fatal.
    let r = recipe(7, time: 30, [need(200, 100, subs: [201])])
    let input = input(
      recipes: [r], slots: [10, 11],
      stock: [stock(200, 100), stock(201, 300)], maxRepeats: 2)

    let assignment = [slot(10), slot(11)].map { ($0, r) }
    let rows = WeeklyPlanConsumption.allocate(
      assignment: assignment, stock: input.stockByID, constraints: input.constraints)
    XCTAssertEqual(rows.count, 2)
    // Slot 10: resolved through the substitute.
    XCTAssertEqual(rows[0].slotId, 10)
    XCTAssertEqual(rows[0].ingredientId, 200)
    XCTAssertEqual(rows[0].resolvedIngredientId, 201)
    XCTAssertTrue(rows[0].substituted)
    XCTAssertEqual(rows[0].grams, 200, accuracy: 1e-9)
    XCTAssertEqual(rows[0].shortfallGrams, 0, accuracy: 1e-9)
    // Slot 11: the substitute is drained; the primary falls 100 g short.
    XCTAssertEqual(rows[1].slotId, 11)
    XCTAssertEqual(rows[1].resolvedIngredientId, 200)
    XCTAssertFalse(rows[1].substituted)
    XCTAssertEqual(rows[1].grams, 100, accuracy: 1e-9)
    XCTAssertEqual(rows[1].shortfallGrams, 100, accuracy: 1e-9)

    let result = WeeklyPlanEngine.plan(input)
    guard case .infeasible(let violations) = result.verdict else {
      return XCTFail("200 + 200 needed, 100 + 300 on hand → infeasible")
    }
    // Violations name the planned primary with the hand-computed shortfall.
    XCTAssertTrue(
      violations.contains { $0 == .insufficientStock(ingredientId: 200, shortfallGrams: 100) },
      "violations were \(violations)")
    // Infeasible results never carry shortage rows (documented).
    XCTAssertTrue(result.shortages.isEmpty)
  }

  // MARK: Case 3 — optional need through a short substitute is visible

  func testOptionalSubstitutedShortfallIsGrouped() {
    // Recipe 7, optional 100 g/serving of 100 with substitute 201;
    // servings 2 → 200 g. 100 is hard-excluded; 201 has 120 g known.
    //
    // Allowed candidates: [201]. 120 < 200 → no full cover → 201 inherits the
    // need: take 120, shortfall 80, substituted (resolved ≠ planned).
    // Optional → feasible.
    //
    // Grouped shortages must show BOTH sides:
    //   (100, substituted):  needed 120, available 0, shortfall 0, sub 201
    //   (201, shortQuantity): needed 120 + 80 = 200, available 120, shortfall 80
    let r = recipe(7, time: 30, [need(100, 100, optional: true, subs: [201])])
    let input = input(
      recipes: [r], slots: [10], stock: [stock(201, 120)], excluded: [100])

    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(result.shortages.count, 2, "the substitution note AND the substitute's shortfall")
    XCTAssertEqual(
      result.shortages,
      [
        WeeklyPlanShortage(
          ingredientId: 100, category: .substituted, neededGrams: 120,
          availableGrams: 0, shortfallGrams: 0, affectedRecipeIds: [7],
          substituteIngredientId: 201),
        WeeklyPlanShortage(
          ingredientId: 201, category: .shortQuantity, neededGrams: 200,
          availableGrams: 120, shortfallGrams: 80, affectedRecipeIds: [7]),
      ])
  }

  // MARK: Case 4 — unknown quantity never covers, never decrements

  func testUnknownQuantityRowsAreExactAndStockIsUntouched() {
    // Recipe 7, required 100 g/serving of 400; servings 2 → 200 g per slot.
    // Stock: 400 present only as an unconfirmed estimate (9,999 g claimed).
    // Per slot: known = false → available counted 0 → take 0, shortfall 200.
    // Two slots, maxRepeats 2 → two identical rows; the estimate is never
    // consumed between slots.
    let r = recipe(7, time: 30, [need(400, 100)])
    let input = input(
      recipes: [r], slots: [10, 11], stock: [stock(400, 9_999, known: false)], maxRepeats: 2)

    let assignment = [slot(10), slot(11)].map { ($0, r) }
    let rows = WeeklyPlanConsumption.allocate(
      assignment: assignment, stock: input.stockByID, constraints: input.constraints)
    XCTAssertEqual(rows.count, 2)
    for (index, expectedSlot) in [Int64(10), Int64(11)].enumerated() {
      XCTAssertEqual(rows[index].slotId, expectedSlot)
      XCTAssertEqual(rows[index].grams, 0, accuracy: 1e-9)
      XCTAssertEqual(rows[index].shortfallGrams, 200, accuracy: 1e-9)
      XCTAssertEqual(rows[index].resolvedIngredientId, 400)
    }

    let result = WeeklyPlanEngine.plan(input)
    guard case .infeasible(let violations) = result.verdict else {
      return XCTFail("an unconfirmed estimate cannot back a required need")
    }
    XCTAssertTrue(
      violations.contains { $0 == .unknownAmountCannotCover(ingredientId: 400) },
      "violations were \(violations)")
  }

  // MARK: Case 5 — repetition penalty, scored by hand

  func testRepetitionPenaltyScoreIsHandComputed() {
    // One recipe, time 20 min, required 50 g/serving of 500; servings 1.
    // Three slots, maxRepeats 3, stock 500 g → each slot covers 50 g.
    // use-soon: no urgencies → 0. time: 0.05 × 3 × 20 = 3.
    // repetition: 3 uses → 2 extra × 2.0 = 4. Score = 0 − 3 − 4 = −7.
    let r = recipe(7, time: 20, [need(500, 50)])
    let input = input(
      recipes: [r], slots: [10, 11, 12], stock: [stock(500, 500)], maxRepeats: 3, servings: 1)

    let result = WeeklyPlanEngine.plan(input)
    XCTAssertEqual(result.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(result.assignments.count, 3)
    XCTAssertEqual(result.score, -7, accuracy: 1e-9)

    let assignment = result.assignments.map { a in
      (slot: WeeklyPlanSlot(id: a.slotId, label: a.slotLabel), recipe: r)
    }
    let rows = WeeklyPlanConsumption.allocate(
      assignment: assignment, stock: input.stockByID, constraints: input.constraints)
    XCTAssertEqual(rows.count, 3)
    for row in rows {
      XCTAssertEqual(row.grams, 50, accuracy: 1e-9)
      XCTAssertEqual(row.shortfallGrams, 0, accuracy: 1e-9)
      XCTAssertEqual(row.resolvedIngredientId, 500)
    }
  }

  // MARK: Case 6 — exclusion decides, even against a much higher score

  func testExclusionBeatsHigherScoringWaiver() {
    // Recipe 1: 200 g/serving of 100, time 10. Recipe 2: 200 g/serving of 101,
    // time 90. servings 2 → 400 g each. Urgency: 100 = 0.5 pts/g.
    // Stock: 1,000 g of 100 and of 101.
    //
    // Without exclusions the engine picks recipe 1 (use-soon 0.5 × 400 = 200,
    // score 200 − 0.5 = 199.5) over recipe 2 (0 − 4.5 = −4.5).
    // With 100 hard-excluded, recipe 1 is ineligible; waiving for +204 points
    // must not happen. The plan is recipe 2, scored 0 − 0.05 × 90 = −4.5, and
    // nothing may resolve to 100.
    let highUrgency = recipe(1, time: 10, [need(100, 200)])
    let excludedFree = recipe(2, time: 90, [need(101, 200)])
    let excludedInput = input(
      recipes: [highUrgency, excludedFree], slots: [10],
      stock: [stock(100, 1_000), stock(101, 1_000)], excluded: [100], urgency: [100: 0.5])
    let freeInput = input(
      recipes: [highUrgency, excludedFree], slots: [10],
      stock: [stock(100, 1_000), stock(101, 1_000)], urgency: [100: 0.5])

    let freeResult = WeeklyPlanEngine.plan(freeInput)
    XCTAssertEqual(freeResult.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(freeResult.assignments.first?.recipeId, 1, "without exclusions the urgent recipe wins")

    let excludedResult = WeeklyPlanEngine.plan(excludedInput)
    XCTAssertEqual(excludedResult.verdict, WeeklyPlanVerdict.feasible)
    XCTAssertEqual(excludedResult.assignments.first?.recipeId, 2)
    XCTAssertEqual(excludedResult.score, -4.5, accuracy: 1e-9)

    let rows = WeeklyPlanConsumption.allocate(
      assignment: [(slot(10), excludedFree)],
      stock: excludedInput.stockByID, constraints: excludedInput.constraints)
    XCTAssertTrue(
      rows.allSatisfy { $0.resolvedIngredientId != 100 && $0.ingredientId != 100 },
      "no excluded consumption allowed, rows were \(rows)")
  }
}
