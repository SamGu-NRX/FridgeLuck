import XCTest
@testable import WeeklyPlanCore

/// Store round trips, relaunch restoration, and flow transitions: edits
/// revalidate and demote acceptance, infeasible drafts cannot be accepted,
/// staleness is fingerprint-driven, and nothing writes during evaluation.
final class StoreFlowTests: XCTestCase {

  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDirectory)
  }

  private func makeInput(stockGrams: Double = 1_000) -> WeeklyPlanInput {
    let recipe = WeeklyPlanRecipe(
      id: 1, title: "Pasta", timeMinutes: 30, dietClass: nil,
      needs: [WeeklyPlanNeed(ingredientId: 100, gramsPerServing: 200, isOptional: false, substitutes: [])])
    let recipe2 = WeeklyPlanRecipe(
      id: 2, title: "Salad", timeMinutes: 15, dietClass: nil,
      needs: [WeeklyPlanNeed(ingredientId: 101, gramsPerServing: 150, isOptional: false, substitutes: [])])
    return WeeklyPlanInput(
      slots: [WeeklyPlanSlot(id: 10, label: "Monday"), WeeklyPlanSlot(id: 11, label: "Tuesday")],
      recipes: [recipe, recipe2],
      stock: [
        WeeklyPlanStockItem(ingredientId: 100, availableGrams: stockGrams, quantityIsKnown: true),
        WeeklyPlanStockItem(ingredientId: 101, availableGrams: 1_000, quantityIsKnown: true),
      ],
      constraints: WeeklyPlanConstraints(
        excludedIngredientIds: [], requiredDietClass: nil, maxCookTimeMinutes: nil,
        servingsPerMeal: 2, maxRepeatsPerRecipe: 3))
  }

  // MARK: store

  func testStoreRoundTripPreservesTheEntry() throws {
    let store = WeeklyPlanStore(directory: tempDirectory)
    let state = WeeklyPlanFlow.propose(inputs: makeInput(), now: Date(timeIntervalSince1970: 1_700_000_000))
    try store.save(state.entry!)

    let loaded = store.load()
    XCTAssertEqual(loaded, state.entry)
    XCTAssertEqual(loaded?.phase, .draft)
    XCTAssertEqual(loaded?.plan.assignments.count, 2)
  }

  func testCorruptStoreReadsAsNoPlan() throws {
    let store = WeeklyPlanStore(directory: tempDirectory)
    try Data("not json".utf8).write(
      to: tempDirectory.appendingPathComponent(WeeklyPlanStore.defaultFileName))
    XCTAssertNil(store.load())
  }

  func testRemoveClearsTheStore() throws {
    let store = WeeklyPlanStore(directory: tempDirectory)
    let state = WeeklyPlanFlow.propose(inputs: makeInput(), now: Date())
    try store.save(state.entry!)
    try store.remove()
    XCTAssertNil(store.load())
  }

  // MARK: relaunch + staleness

  func testRestoreKeepsAcceptedPhaseAndFlagsStalenessOnDriftedInputs() throws {
    let inputs = makeInput()
    var state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    state = WeeklyPlanFlow.accept(state: state, now: Date())
    XCTAssertTrue(state.isAccepted)

    // Relaunch with identical inputs: accepted plan, not stale.
    let fresh = WeeklyPlanFlow.restore(entry: state.entry, inputs: inputs)
    XCTAssertTrue(fresh.isAccepted)
    XCTAssertFalse(fresh.isStale)

    // Stock drifts (ingredients consumed offline): fingerprint changes, the
    // plan is flagged stale, and nothing about it is silently rewritten.
    let drifted = makeInput(stockGrams: 200)
    let relaunched = WeeklyPlanFlow.restore(entry: state.entry, inputs: drifted)
    XCTAssertTrue(relaunched.isAccepted)
    XCTAssertTrue(relaunched.isStale)
    XCTAssertEqual(relaunched.plan, state.plan)
  }

  func testEvaluateStalenessDoesNotTouchThePlan() {
    let inputs = makeInput()
    let state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    var drifted = makeInput()
    drifted.constraints.servingsPerMeal = 4
    let evaluated = WeeklyPlanFlow.evaluateStaleness(state: state, inputs: drifted)
    XCTAssertTrue(evaluated.isStale)
    XCTAssertEqual(evaluated.plan, state.plan)
  }

  // MARK: flow transitions

  func testAcceptThenEditDemotesToDraftAndClearsAcceptance() {
    let inputs = makeInput()
    var state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    state = WeeklyPlanFlow.accept(state: state, now: Date())
    XCTAssertTrue(state.isAccepted)
    let slot11Before = state.plan?.assignments.first(where: { $0.slotId == 11 })?.recipeId

    let edited = WeeklyPlanFlow.editSlot(
      state: state, slotId: 10, newRecipeId: 2, inputs: inputs, now: Date())
    XCTAssertEqual(edited.entry?.phase, .draft)
    XCTAssertNil(edited.entry?.acceptedAt)
    XCTAssertNotNil(edited.entry?.lastEditedAt)
    XCTAssertEqual(edited.plan?.assignments.first(where: { $0.slotId == 10 })?.recipeId, 2)
    // The other slot kept its recipe.
    XCTAssertEqual(edited.plan?.assignments.first(where: { $0.slotId == 11 })?.recipeId, slot11Before)
    // Fingerprint stays the plan's original: staleness stays honest.
    XCTAssertEqual(edited.plan?.fingerprint, state.plan?.fingerprint)
  }

  func testEditThatBreaksFeasibilityIsRejectedAndKeepsTheAcceptedPlan() {
    // 500 g of ingredient 100 on hand: slot 10 with Pasta uses 400 g, so
    // moving Pasta into slot 11 as well (800 g total) must be rejected.
    let inputs = makeInput(stockGrams: 500)
    var state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    state = WeeklyPlanFlow.accept(state: state, now: Date())
    XCTAssertTrue(state.isAccepted)

    let rejected = WeeklyPlanFlow.editSlot(
      state: state, slotId: 11, newRecipeId: 1, inputs: inputs, now: Date())
    XCTAssertNotNil(rejected.rejectionReason)
    XCTAssertEqual(rejected.entry, state.entry, "a rejected edit changes nothing")
    XCTAssertTrue(rejected.isAccepted)
  }

  func testInfeasibleDraftCannotBeAccepted() {
    // Only Pasta is offered, and the stock for its ingredient is zero: the
    // only possible plan is infeasible, so acceptance must be rejected.
    let recipe = WeeklyPlanRecipe(
      id: 1, title: "Pasta", timeMinutes: 30, dietClass: nil,
      needs: [WeeklyPlanNeed(ingredientId: 100, gramsPerServing: 200, isOptional: false, substitutes: [])])
    let inputs = WeeklyPlanInput(
      slots: [WeeklyPlanSlot(id: 10, label: "Monday")],
      recipes: [recipe],
      stock: [WeeklyPlanStockItem(ingredientId: 100, availableGrams: 0, quantityIsKnown: true)])
    let state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    // The plan over zero stock is infeasible for Pasta: verify that first so
    // the accept-gating assertion is meaningful.
    guard let plan = state.plan, !plan.isFeasible else {
      return XCTFail("zero stock should not have produced a feasible plan here")
    }
    XCTAssertFalse(plan.violations.isEmpty, "infeasibility must carry a reason")
    let accepted = WeeklyPlanFlow.accept(state: state, now: Date())
    XCTAssertNotNil(accepted.rejectionReason)
    XCTAssertEqual(accepted.entry?.phase, .draft)
  }

  func testRemoveSlotRebuildsShortagesAndDemotesAcceptance() {
    let inputs = makeInput()
    var state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    state = WeeklyPlanFlow.accept(state: state, now: Date())

    let removed = WeeklyPlanFlow.removeSlot(state: state, slotId: 11, inputs: inputs, now: Date())
    XCTAssertEqual(removed.entry?.phase, .draft)
    XCTAssertEqual(removed.plan?.assignments.count, 1)
    XCTAssertFalse(removed.plan?.slots.contains { $0.id == 11 } ?? true)
  }

  func testRecomputeSupersedesAcceptance() {
    let inputs = makeInput()
    var state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    state = WeeklyPlanFlow.accept(state: state, now: Date())
    let recomputed = WeeklyPlanFlow.recompute(state: state, inputs: inputs, now: Date())
    XCTAssertEqual(recomputed.entry?.phase, .draft)
    XCTAssertNil(recomputed.entry?.acceptedAt)
    XCTAssertFalse(recomputed.isStale)
  }

  func testDiscardClearsEverything() {
    let inputs = makeInput()
    let state = WeeklyPlanFlow.propose(inputs: inputs, now: Date())
    let cleared = WeeklyPlanFlow.discard(state: state)
    XCTAssertNil(cleared.entry)
    XCTAssertFalse(cleared.isStale)
  }
}
