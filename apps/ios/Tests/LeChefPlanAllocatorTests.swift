import XCTest

@testable import FridgeLuck
import FLFeatureLogic

/// Allocator behavior (SPEC.md §7): deterministic, FIFO use-soon, no double counting, honest
/// line states, hard allergen filter, merged shopping shortfall.
final class LeChefPlanAllocatorTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func lot(
    _ id: Int64, _ grams: Double, expiresIn: Double? = nil, estimate: Bool = false
  ) -> PlanLot {
    PlanLot(
      ingredientID: id, grams: grams,
      expiresAt: expiresIn.map { now.addingTimeInterval($0) }, quantityIsEstimate: estimate)
  }

  private func candidate(
    _ id: Int64, title: String = "Recipe", servings: Int = 2, minutes: Int? = 30,
    lines: [PlanCandidateLine]
  ) -> PlanCandidate {
    PlanCandidate(
      databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1), title: title,
      timeMinutes: minutes, baseServings: servings, lines: lines)
  }

  private func line(_ id: Int64, name: String, grams: Double, required: Bool = true) -> PlanCandidateLine {
    PlanCandidateLine(ingredientID: id, name: name, grams: grams, isRequired: required)
  }

  private func request(
    dinners: Int = 1, servings: [Int] = [], candidates: [PlanCandidate], pool: StockPool,
    staples: Set<Int64> = [], eaters: [PlanEater] = [], substitutions: [PlanSubstitution] = [],
    excluded: Set<Int64> = []
  ) -> PlanRequest {
    PlanRequest(
      dinnerCount: dinners, servingsPerDinner: servings, candidates: candidates, eaters: eaters,
      substitutions: substitutions, stapleIngredientIDs: staples, pool: pool,
      excludeDatabaseIDs: excluded, planID: "plan_test", createdAt: now)
  }

  // MARK: - Determinism and ordering

  func testSameInputProducesSameOutput() {
    let candidates = [
      candidate(1, lines: [line(10, name: "rice", grams: 200)]),
      candidate(2, lines: [line(10, name: "rice", grams: 100), line(11, name: "beans", grams: 100)]),
    ]
    let make = {
      PlanAllocating.allocate(
        self.request(
          dinners: 2, candidates: candidates,
          pool: StockPool(lots: [self.lot(10, 400), self.lot(11, 200)], now: self.now)))
    }
    let first = make()
    let second = make()
    XCTAssertEqual(first, second)
  }

  func testUseSoonStockIsChosenFirstAndCountsTriple() {
    // Recipe A uses ingredient 10 (expires in 2 days, inside the 3-day horizon).
    // Recipe B uses ingredient 11 (no expiry). Both fully covered by 100 g.
    let useSoonRecipe = candidate(1, lines: [line(10, name: "spinach", grams: 100)])
    let pantryRecipe = candidate(2, lines: [line(11, name: "rice", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 2, candidates: [pantryRecipe, useSoonRecipe],
        pool: StockPool(
          lots: [
            // The use-soon lot is deliberately listed later; ranking must not depend on input order.
            lot(11, 100), lot(10, 100, expiresIn: 2 * 86_400),
          ], now: now)))
    XCTAssertEqual(plan.dinners.first?.recipeDatabaseID, 1)
    // Servings are 2 by default; the fit line reflects line states, not a percentage.
    XCTAssertEqual(plan.fitSummary.sufficientLines, 2)
    XCTAssertEqual(plan.fitSummary.totalLines, 2)
  }

  func testExpiryTiesKeepStableOrderRegardlessOfInputOrder() {
    // Two lots of the same ingredient with identical expiry; the pool must aggregate in the
    // same total and order whichever way the raw lots arrive.
    let a = StockPool(
      lots: [lot(10, 100, expiresIn: 86_400), lot(10, 200, expiresIn: 86_400)], now: now)
    let b = StockPool(
      lots: [lot(10, 200, expiresIn: 86_400), lot(10, 100, expiresIn: 86_400)], now: now)
    XCTAssertEqual(a.entry(for: 10)?.totalGrams, 300)
    XCTAssertEqual(a, b)
  }

  // MARK: - No double counting

  func testReservedStockIsNotCountedByTheNextDinner() {
    // Two recipes each need 300 g of ingredient 10; only 500 g exist.
    let a = candidate(1, lines: [line(10, name: "pasta", grams: 300)])
    let b = candidate(2, lines: [line(10, name: "noodles", grams: 300)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 2, candidates: [a, b], pool: StockPool(lots: [lot(10, 500)], now: now)))
    XCTAssertEqual(plan.dinners.count, 2)
    // Dinner 1 takes 300 g; dinner 2 can only be covered for 200 g and must be short 100 g.
    let second = plan.dinners[1]
    let shortLines = second.lines.filter { $0.lineState == .short }
    XCTAssertEqual(shortLines.count, 1)
    XCTAssertEqual(shortLines.first?.short?.value ?? 0, 100, accuracy: 0.001)
    // The merged shopping list carries exactly one 100 g entry — not 300 + 300.
    XCTAssertEqual(plan.shoppingList.count, 1)
    XCTAssertEqual(plan.shoppingList.first?.amount.value ?? 0, 100, accuracy: 0.001)
  }

  func testSameIngredientCannotBeCountedByTwoLines() {
    // A recipe whose bill has the ingredient twice (adapters dedupe; the guarantee must not
    // depend on that): 500 g demand, 300 g stock → one line, short 200 g, one buy of 200 g.
    let doubled = candidate(
      1, lines: [line(10, name: "flour", grams: 250), line(10, name: "flour", grams: 250)])
    let plan = PlanAllocating.allocate(
      request(candidates: [doubled], pool: StockPool(lots: [lot(10, 300)], now: now)))
    XCTAssertEqual(plan.dinners[0].lines.count, 1)
    XCTAssertEqual(plan.dinners[0].lines[0].short?.value ?? 0, 200, accuracy: 0.001)
    XCTAssertEqual(plan.shoppingList.count, 1)
    XCTAssertEqual(plan.shoppingList.first?.amount.value ?? 0, 200, accuracy: 0.001)
  }

  // MARK: - Line states

  func testEstimateCoveredLineIsNeedsReconfirmingNotSufficient() {
    let recipe = candidate(1, lines: [line(10, name: "onions", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        candidates: [recipe],
        pool: StockPool(
          lots: [lot(10, 200, expiresIn: 86_400, estimate: true)], now: now)))
    XCTAssertEqual(plan.dinners[0].lines[0].lineState, .needsReconfirming)
    // Estimation shows up as attention, but nothing is bought.
    XCTAssertEqual(plan.shoppingList, [])
  }

  func testUnknownQuantityIsNeverSufficientAndNeverBought() {
    let recipe = candidate(1, lines: [line(10, name: "salt", grams: 0)])
    let plan = PlanAllocating.allocate(
      request(candidates: [recipe], pool: StockPool(lots: [lot(10, 500)], now: now)))
    XCTAssertEqual(plan.dinners[0].lines[0].lineState, .quantityUnknown)
    XCTAssertEqual(plan.shoppingList, [])
  }

  func testMissingStapleIsStruckThroughOnTheList() {
    let recipe = candidate(1, lines: [line(10, name: "olive oil", grams: 20)])
    let plan = PlanAllocating.allocate(
      request(candidates: [recipe], staples: [10], pool: StockPool(lots: [], now: now)))
    XCTAssertEqual(plan.dinners[0].lines[0].lineState, .assumedStaple)
    XCTAssertEqual(plan.shoppingList.first?.assumedStaple, true)
  }

  func testShortfallMergesAcrossDinnersPerIngredient() {
    // Two dinners each short 50 g of the same ingredient buy one 100 g line, not two 50 g lines.
    let a = candidate(1, lines: [line(10, name: "carrots", grams: 150)])
    let b = candidate(2, lines: [line(10, name: "carrots", grams: 150)])
    let plan = PlanAllocating.allocate(
      request(dinners: 2, candidates: [a, b], pool: StockPool(lots: [lot(10, 100)], now: now)))
    XCTAssertEqual(plan.shoppingList.count, 1)
    XCTAssertEqual(plan.shoppingList.first?.amount.value ?? 0, 200, accuracy: 0.001)
  }

  // MARK: - Servings

  func testServingsScaleTheBillAgainstTheRecipeBase() {
    // Recipe serves 2 and needs 200 g; dinner asks 4 servings → 400 g demand, 300 g stock.
    let recipe = candidate(1, lines: [line(10, name: "rice", grams: 200)])
    let plan = PlanAllocating.allocate(
      request(
        servings: [4], candidates: [recipe], pool: StockPool(lots: [lot(10, 300)], now: now)))
    let short = plan.dinners[0].lines[0]
    XCTAssertEqual(short.lineState, .short)
    XCTAssertEqual(short.short?.value ?? 0, 100, accuracy: 0.001)
  }

  // MARK: - Substitutions

  func testSubstitutionOnlyAppliesWhenItFullyCoversTheShortfall() {
    // 300 g demand, 200 g stock: 100 g short. Substitute 11 converts 1:1 and has 300 g.
    let recipe = candidate(1, lines: [line(10, name: "butter", grams: 300)])
    let plan = PlanAllocating.allocate(
      request(
        candidates: [recipe],
        substitutions: [PlanSubstitution(originalID: 10, substituteID: 11, substituteGramsPerOriginalGram: 1, note: "margarine", reviewed: true)],
        pool: StockPool(lots: [lot(10, 200), lot(11, 300)], now: now)))
    let swapped = plan.dinners[0].lines[0]
    XCTAssertEqual(swapped.lineState, .sufficient)
    XCTAssertEqual(swapped.swap?.substituteID, 11)
    XCTAssertEqual(swapped.swap?.reviewed, true)
    // The substitute's grams are reserved: a second dinner cannot claim them again.
    let second = PlanAllocating.allocate(
      request(
        dinners: 2, candidates: [recipe, candidate(2, lines: [line(11, name: "margarine", grams: 250)])],
        substitutions: [PlanSubstitution(originalID: 10, substituteID: 11, substituteGramsPerOriginalGram: 1, note: "margarine", reviewed: true)],
        pool: StockPool(lots: [lot(10, 200), lot(11, 300)], now: now)))
    XCTAssertEqual(second.dinners[1].lines[0].lineState, .short)
  }

  func testShortfallIsReportedWhenNoSubstituteCoversIt() {
    let recipe = candidate(1, lines: [line(10, name: "butter", grams: 300)])
    let plan = PlanAllocating.allocate(
      request(
        candidates: [recipe],
        substitutions: [PlanSubstitution(originalID: 10, substituteID: 11, substituteGramsPerOriginalGram: 1, note: "margarine", reviewed: true)],
        pool: StockPool(lots: [lot(10, 200), lot(11, 50)], now: now)))
    XCTAssertEqual(plan.dinners[0].lines[0].lineState, .short)
    XCTAssertEqual(plan.dinners[0].lines[0].swap, nil)
  }

  // MARK: - Restrictions and exclusion

  func testAllergenIsAHardFilterEvenWhenWaivingWouldScoreHigher() {
    // Eater is allergic to ingredient 10 (the only fully-covered recipe). The plan must skip it
    // rather than suggest it with a waiver.
    let allergic = candidate(1, lines: [line(10, name: "peanuts", grams: 100)])
    let safe = candidate(2, lines: [line(11, name: "oats", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 1, candidates: [allergic, safe],
        eaters: [PlanEater(id: "e1", blockedIngredientIDs: [10])],
        pool: StockPool(lots: [lot(10, 100), lot(11, 100)], now: now)))
    XCTAssertEqual(plan.dinners.count, 1)
    XCTAssertEqual(plan.dinners[0].recipeDatabaseID, 2)
  }

  func testOptionalLinesNeverEnterTheShoppingList() {
    // 100 g stock, 300 g demand on an optional line: display-short, not blocking, not bought.
    let recipe = candidate(1, lines: [line(10, name: "parsley", grams: 300, required: false)])
    let plan = PlanAllocating.allocate(
      request(candidates: [recipe], pool: StockPool(lots: [lot(10, 100)], now: now)))
    XCTAssertEqual(plan.dinners[0].lines[0].lineState, .short)
    XCTAssertEqual(plan.shoppingList, [])
    XCTAssertEqual(plan.fitSummary.totalLines, 0)
  }

  func testExcludedCandidatesAreSkipped() {
    let a = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let b = candidate(2, lines: [line(11, name: "beans", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 1, candidates: [a, b], pool: StockPool(lots: [lot(10, 100), lot(11, 100)],
        now: now), excluded: [1]))
    XCTAssertEqual(plan.dinners.first?.recipeDatabaseID, 2)
  }

  // MARK: - Honest emptiness

  func testNothingFeasibleYieldsEmptyPlanWithoutFakeDinners() {
    let impossible = candidate(1, lines: [line(10, name: "saffron", grams: 500)])
    let plan = PlanAllocating.allocate(
      request(candidates: [impossible], pool: StockPool(lots: [], now: now)))
    XCTAssertEqual(plan.dinners, [])
  }

  func testSparseKitchenYieldsFewerThanRequestedDinners() {
    let a = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: [a],
        pool: StockPool(
          lots: [lot(10, 100), lot(11, 100), lot(12, 100)], now: now)))
    XCTAssertEqual(plan.dinners.count, 1)
  }

  // MARK: - Schema shape

  func testPlanShapeMatchesTheContract() {
    let recipe = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(candidates: [recipe], pool: StockPool(lots: [lot(10, 100)], now: now)))
    XCTAssertTrue(plan.planID.hasPrefix("plan_"))
    XCTAssertEqual(plan.dinners[0].dinnerID, "plan_test-d1")
    XCTAssertEqual(plan.dinners[0].position, 1)
    XCTAssertEqual(plan.dinners[0].recipe.source, .catalog)
    XCTAssertEqual(plan.dinners[0].recipe.id, "1")
  }
}
