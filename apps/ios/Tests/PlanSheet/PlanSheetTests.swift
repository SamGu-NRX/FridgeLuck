import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The plan sheet over fake snapshots: what each state puts on screen (`PlanSheetContent`, the
/// only input `PlanSheetView` renders), the edits the sheet offers, and the Home entry point.
@MainActor
final class PlanSheetTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Fixtures

  private func line(_ id: Int64, _ name: String, _ grams: Double) -> PlanCandidateLine {
    PlanCandidateLine(ingredientID: id, name: name, grams: grams, isRequired: true)
  }

  private func recipe(_ id: Int64, _ title: String, _ lines: [PlanCandidateLine]) -> PlanCandidate {
    PlanCandidate(
      databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1),
      title: title, timeMinutes: 30, baseServings: 2, lines: lines)
  }

  private func lot(_ id: Int64, _ grams: Double) -> PlanLot {
    PlanLot(ingredientID: id, grams: grams, expiresAt: nil, quantityIsEstimate: false)
  }

  private func snapshot(
    _ candidates: [PlanCandidate], lots: [PlanLot], eaters: [PlanEater] = [],
    substitutions: [PlanSubstitution] = [], staples: Set<Int64> = [], hasLots: Bool = true
  ) -> PlanSheetData {
    PlanSheetData(
      candidates: candidates, eaters: eaters, substitutions: substitutions,
      stapleIngredientIDs: staples, pool: StockPool(lots: lots, now: now),
      hasAnyStockLots: hasLots)
  }

  private func loadedModel(_ data: PlanSheetData, saves: Bool = true) async -> PlanSheetViewModel {
    let saver: (@Sendable (LeChefPlan) async throws -> Void)? = saves ? { @Sendable _ in } : nil
    let model = PlanSheetViewModel(now: now, provider: { _ in data }, saver: saver)
    await model.load()
    return model
  }

  private func recipeIDs(_ model: PlanSheetViewModel) -> [Int64] {
    model.plan?.dinners.map(\.recipeDatabaseID) ?? []
  }

  // MARK: - States

  func testEmptyKitchenSaysItDoesNotKnowTheKitchenAndPlansNothing() async {
    let model = await loadedModel(
      snapshot([recipe(1, "Fried rice", [line(10, "rice", 200)])], lots: [], hasLots: false))
    let content = PlanSheetContent(model)

    XCTAssertEqual(model.state, .empty)
    XCTAssertEqual(content.kind, .emptyKitchen)
    XCTAssertEqual(content.headline, "I don't know your kitchen yet")
    XCTAssertEqual(
      content.message, "Add what you have, or scan your shelf, and I'll plan dinners from it.")
    XCTAssertEqual(content.dinners, [])
    XCTAssertEqual(content.shopping, [])
    XCTAssertNil(content.save)
    XCTAssertFalse(content.showsPlanControls)
  }

  func testNothingFeasibleLeadsWithTheShopAndNeverOffersADinnerAsCookable() async throws {
    // Pancakes miss three ingredients (one over the limit), so nothing is plannable. The
    // peanut dish would also make the shop-first list, but the household blocks peanuts.
    let data = snapshot(
      [
        recipe(1, "Pancakes", [line(20, "flour", 200), line(21, "egg", 100), line(22, "milk", 300)]),
        recipe(2, "Peanut noodles", [
          line(25, "peanuts", 100), line(26, "noodles", 100), line(27, "scallion", 20),
        ]),
      ],
      lots: [lot(10, 100)],
      eaters: [PlanEater(id: "household", blockedIngredientIDs: [25])])
    let model = await loadedModel(data)
    let content = PlanSheetContent(model)

    XCTAssertEqual(model.state, .nothingFeasible)
    XCTAssertEqual(model.plan?.dinners, [], "no dinner is planned as cookable")
    XCTAssertEqual(
      model.shoppingFirstPlan?.dinners.map(\.recipeDatabaseID), [1],
      "the shop-first plan still passes the household screen")
    XCTAssertEqual(content.kind, .nothingFits)
    XCTAssertEqual(content.headline, "Nothing fits what you have yet")
    XCTAssertEqual(
      content.message,
      "Every dinner is missing more than two ingredients. This shop would cover the dinner below.")
    let card = try XCTUnwrap(content.dinners.first)
    XCTAssertEqual(content.dinners.count, 1)
    XCTAssertEqual(card.title, "Pancakes")
    XCTAssertEqual(card.fitText, "Needs a shop · 3 to buy")
    XCTAssertFalse(card.canSwap)
    XCTAssertEqual(card.fromKitchen, [])
    XCTAssertEqual(
      card.toBuy,
      [
        .init(name: "Flour", detail: "200 g"), .init(name: "Egg", detail: "100 g"),
        .init(name: "Milk", detail: "300 g"),
      ])
    XCTAssertEqual(content.shopping.map(\.name), ["Egg", "Flour", "Milk"])
    XCTAssertEqual(content.shopping.map(\.amountText), ["100 g", "200 g", "300 g"])
    XCTAssertNil(content.save, "a shop-first plan is not offered for saving")
    XCTAssertTrue(content.showsPlanControls)
  }

  func testNoAdmittedRecipesSaysSoWithoutAShoppingList() async {
    let model = await loadedModel(snapshot([], lots: [lot(10, 100)]))
    let content = PlanSheetContent(model)

    XCTAssertEqual(model.state, .nothingFeasible)
    XCTAssertNil(model.shoppingFirstPlan)
    XCTAssertEqual(content.kind, .noRecipes)
    XCTAssertEqual(content.headline, "No recipes to plan from")
    XCTAssertEqual(content.dinners, [])
    XCTAssertEqual(content.shopping, [])
  }

  func testPlannedWeekShowsServingsKitchenLinesSwapsAndReadableShoppingNames() async throws {
    // Chicken rice: rice covered, chicken short, salt has no amount. Yogurt dip: sour cream is
    // half stocked and the reviewed swap covers the rest; olive oil is a staple with no stock.
    let data = snapshot(
      [
        recipe(1, "Chicken rice", [
          line(10, "rice", 200), line(11, "chicken_breast", 300), line(15, "salt", 0),
        ]),
        recipe(2, "Yogurt dip", [line(12, "sour_cream", 100), line(14, "olive_oil", 15)]),
      ],
      lots: [lot(10, 400), lot(12, 50), lot(13, 300)],
      substitutions: [
        PlanSubstitution(
          originalID: 12, substituteID: 13, substituteGramsPerOriginalGram: 1, note: "a little tangier",
          reviewed: true, substituteName: "greek_yogurt")
      ],
      staples: [14])
    let model = await loadedModel(data)
    let content = PlanSheetContent(model)

    XCTAssertEqual(content.kind, .planned)
    XCTAssertEqual(content.title, "Next 3 dinners")
    XCTAssertEqual(content.notes, ["Your kitchen covers 2 of the 3 dinners you asked for."])
    XCTAssertEqual(content.save, .save)
    XCTAssertEqual(content.dinners.count, 2)

    let rice = content.dinners[0]
    XCTAssertEqual(rice.positionLabel, "Dinner 1")
    XCTAssertEqual(rice.title, "Chicken rice")
    XCTAssertEqual(rice.timeText, "30 min")
    XCTAssertEqual(rice.servings, 2)
    XCTAssertTrue(rice.canChangeServings)
    XCTAssertTrue(rice.canSwap)
    XCTAssertEqual(rice.fromKitchen, [.init(name: "Rice", detail: "200 g")])
    XCTAssertEqual(rice.toBuy, [.init(name: "Chicken Breast", detail: "300 g")])
    XCTAssertEqual(
      rice.toCheck, [.init(name: "Salt", detail: "No amount listed, check you have some")])
    XCTAssertEqual(rice.fitText, "1 of 3 from your kitchen · check chicken breast and salt")
    XCTAssertEqual(
      rice.accessibilitySummary,
      "Dinner 1. Chicken rice. 30 minutes. 2 servings. 1 of 3 from your kitchen · check chicken breast and salt.")

    let dip = content.dinners[1]
    XCTAssertEqual(dip.title, "Yogurt dip")
    XCTAssertEqual(dip.fromKitchen, [.init(name: "Sour Cream", detail: "50 g")])
    XCTAssertEqual(
      dip.substitutions, [.init(name: "Greek Yogurt for Sour Cream", detail: "50 g · a little tangier")])
    XCTAssertEqual(dip.toCheck, [.init(name: "Olive Oil", detail: "Assumed on hand · 15 g")])
    XCTAssertEqual(dip.toBuy, [])
    XCTAssertEqual(dip.fitText, "1 of 2 from your kitchen · check olive oil")

    XCTAssertEqual(content.shopping.map(\.name), ["Chicken Breast", "Olive Oil"])
    XCTAssertEqual(content.shopping.map(\.usuallyOnHand), [false, true])
    XCTAssertEqual(
      content.shopping.map(\.accessibilityLabel),
      ["Chicken Breast, 300 grams", "Olive Oil, 15 grams, you usually have this"])
    XCTAssertNil(content.shoppingEmptyText)
  }

  func testSheetWithoutASaverOffersNoSave() async {
    let model = await loadedModel(
      snapshot([recipe(1, "Fried rice", [line(10, "rice", 200)])], lots: [lot(10, 400)]),
      saves: false)
    XCTAssertEqual(model.state, .ready)
    XCTAssertNil(PlanSheetContent(model).save)
    XCTAssertFalse(model.canSave)
  }

  // MARK: - Controls

  func testChangingTheDinnerCountRecomputesAndKeepsTheDinnersAlreadyShown() async {
    // Four independent dinners, ranked by how much stock each uses.
    let data = snapshot(
      [
        recipe(1, "One", [line(11, "a", 400)]), recipe(2, "Two", [line(12, "b", 300)]),
        recipe(3, "Three", [line(13, "c", 200)]), recipe(4, "Four", [line(14, "d", 100)]),
      ],
      lots: [lot(11, 400), lot(12, 300), lot(13, 200), lot(14, 100)])
    let model = await loadedModel(data)
    XCTAssertEqual(recipeIDs(model), [1, 2, 3])

    model.setDinnerCount(4)
    XCTAssertEqual(recipeIDs(model), [1, 2, 3, 4])
    XCTAssertEqual(PlanSheetContent(model).title, "Next 4 dinners")
    XCTAssertFalse(model.sparseKitchen)

    model.setDinnerCount(2)
    XCTAssertEqual(recipeIDs(model), [1, 2])
    XCTAssertEqual(PlanSheetContent(model).dinners.map(\.title), ["One", "Two"])
  }

  func testServingsChangeReallocatesTheLinesForThatDinner() async throws {
    let model = await loadedModel(
      snapshot([recipe(1, "Fried rice", [line(10, "rice", 200)])], lots: [lot(10, 300)]))
    XCTAssertEqual(PlanSheetContent(model).shopping, [])

    model.setServings(4, forDinnerAt: 0)
    let card = try XCTUnwrap(PlanSheetContent(model).dinners.first)
    XCTAssertEqual(card.servings, 4)
    XCTAssertEqual(card.fromKitchen, [.init(name: "Rice", detail: "300 g")])
    XCTAssertEqual(card.toBuy, [.init(name: "Rice", detail: "100 g")])
  }

  func testSwapReplacesExactlyOneDinner() async throws {
    // Stock x 200, y 150, z 100. The plan is A (x), B (y), C (z). Swapping B brings in F,
    // which takes y 40 and all of z. A fresh greedy pass would then put E (y 110) third
    // instead of C; the swap keeps C, now honestly short of z.
    let data = snapshot(
      [
        recipe(1, "A", [line(10, "x", 200)]),
        recipe(2, "B", [line(11, "y", 150)]),
        recipe(3, "C", [line(12, "z", 100)]),
        recipe(5, "E", [line(11, "y", 110)]),
        recipe(6, "F", [line(11, "y", 40), line(12, "z", 100)]),
      ],
      lots: [lot(10, 200), lot(11, 150), lot(12, 100)])
    let model = await loadedModel(data)
    XCTAssertEqual(recipeIDs(model), [1, 2, 3])

    model.replaceDinner(at: 1)

    XCTAssertEqual(recipeIDs(model), [1, 6, 3], "only the swapped dinner changed")
    XCTAssertNil(model.notice)
    let kept = try XCTUnwrap(model.plan?.dinners[2])
    XCTAssertEqual(kept.lines.map(\.lineState), [.short], "C re-allocated against what F left")

    // A fresh greedy pass over the same pool, for contrast: it would have moved dinner 3.
    let unpinned = PlanAllocating.allocate(
      PlanRequest(
        dinnerCount: 3, candidates: data.candidates, pool: data.pool, excludeDatabaseIDs: [2],
        planID: "plan_x", createdAt: now))
    XCTAssertEqual(unpinned.dinners.map(\.recipeDatabaseID), [1, 6, 5])
  }

  func testSwapWithNothingElseToOfferKeepsThePlanAndSaysSo() async {
    let model = await loadedModel(
      snapshot([recipe(1, "Fried rice", [line(10, "rice", 200)])], lots: [lot(10, 400)]))
    let before = model.plan

    model.replaceDinner(at: 0)

    XCTAssertEqual(model.plan, before)
    XCTAssertEqual(model.notice, "Nothing else fits that night from your kitchen.")
    XCTAssertEqual(
      PlanSheetContent(model).notes,
      [
        "Your kitchen covers 1 of the 3 dinners you asked for.",
        "Nothing else fits that night from your kitchen.",
      ])
  }

  func testShoppingListTotalsMatchTheAllocatorShortfalls() async throws {
    // Eggs are short in both dinners, milk is half stocked, oil is a staple with no stock.
    let data = snapshot(
      [
        recipe(1, "Omelette", [line(30, "egg", 100), line(31, "milk", 300)]),
        recipe(2, "Custard", [line(30, "egg", 60), line(32, "sugar", 50), line(33, "oil", 10)]),
      ],
      lots: [lot(31, 100), lot(32, 50)], staples: [33])
    let model = await loadedModel(data)
    let plan = try XCTUnwrap(model.plan)
    XCTAssertEqual(plan.dinners.map(\.title), ["Omelette", "Custard"])

    // Sum every line the allocator reported short (and every assumed staple) per ingredient.
    var shortfalls: [Int64: Double] = [:]
    for line in plan.dinners.flatMap(\.lines) where line.isRequired {
      switch line.lineState {
      case .short: shortfalls[line.ingredientID, default: 0] += line.short?.value ?? 0
      case .assumedStaple: shortfalls[line.ingredientID, default: 0] += line.required?.value ?? 0
      default: break
      }
    }
    let rows = PlanSheetContent(model).shopping
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.grams) }), shortfalls)
    XCTAssertEqual(shortfalls, [30: 160, 31: 200, 33: 10])
    XCTAssertEqual(rows.map(\.name), ["Egg", "Milk", "Oil"])
    XCTAssertEqual(rows.map(\.amountText), ["160 g", "200 g", "10 g"])
    XCTAssertEqual(rows.map(\.usuallyOnHand), [false, false, true])
  }

  func testSaveMarksThePlanSavedAndAnEditMakesItUnsavedAgain() async throws {
    let saved = SavedPlans()
    let data = snapshot(
      [recipe(1, "Fried rice", [line(10, "rice", 200)])], lots: [lot(10, 400)])
    let model = PlanSheetViewModel(
      now: now, provider: { _ in data }, saver: { plan in await saved.append(plan) })
    await model.load()
    XCTAssertTrue(model.canSave)

    await model.save()
    XCTAssertEqual(model.saveStatus, .saved)
    XCTAssertEqual(PlanSheetContent(model).save, .saved)
    XCTAssertFalse(model.canSave)
    let first = await saved.plans
    XCTAssertEqual(first.map(\.planID), [model.plan?.planID])

    model.setServings(3, forDinnerAt: 0)
    XCTAssertEqual(model.saveStatus, .unsaved)
    await model.save()
    let both = await saved.plans
    XCTAssertEqual(Set(both.map(\.planID)).count, 1, "saving again replaces the same plan")
  }

  func testFailedSaveOffersARetry() async {
    struct DiskFull: Error {}
    let data = snapshot([recipe(1, "Rice", [line(10, "rice", 200)])], lots: [lot(10, 400)])
    let model = PlanSheetViewModel(
      now: now, provider: { _ in data }, saver: { _ in throw DiskFull() })
    await model.load()
    await model.save()
    let content = PlanSheetContent(model)
    XCTAssertEqual(content.save, .retry)
    XCTAssertEqual(content.saveFailureText, "Couldn't save the plan. Try again.")
    XCTAssertTrue(model.canSave)
  }

  func testIngredientNamesReadLikeTheRestOfTheApp() {
    XCTAssertEqual(PlanSheetText.ingredientName("chicken_breast"), "Chicken Breast")
    XCTAssertEqual(PlanSheetText.ingredientName("olive oil"), "Olive Oil")
    XCTAssertEqual(PlanSheetText.ingredientName("Greek yogurt"), "Greek yogurt")
  }

  // MARK: - Entry point

  func testHomeEntryOpensASheetOverTheRealDatabase() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("plan-sheet-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var config = Configuration()
    config.foreignKeysEnabled = true
    let dbQueue = try DatabaseQueue(
      path: root.appendingPathComponent("plan.sqlite").path, configuration: config)
    try DatabaseMigrations.migrate(dbQueue)
    let appDatabase = AppDatabase(dbQueue: dbQueue)
    try await appDatabase.warmBundledContentIfNeeded()
    let deps = AppDependencies(appDatabase: appDatabase)

    // The same construction HomeDashboardView uses.
    let launcher = PlanSheetLauncher(makeModel: { deps.makePlanSheetViewModel() })
    XCTAssertNil(launcher.session)
    launcher.open()
    let session = try XCTUnwrap(launcher.session, "tapping the entry presents the sheet")
    await session.model.load()
    XCTAssertEqual(PlanSheetContent(session.model).kind, .emptyKitchen, "a fresh install has no stock")

    // "Add groceries" closes the sheet first and runs its action once the sheet is gone.
    var opened = 0
    launcher.close(then: { opened += 1 })
    XCTAssertNil(launcher.session)
    XCTAssertEqual(opened, 0)
    launcher.sheetDidDismiss()
    launcher.sheetDidDismiss()
    XCTAssertEqual(opened, 1)

    launcher.open()
    XCTAssertFalse(launcher.session?.model === session.model, "each opening reads the kitchen anew")
  }
}

/// Records what a saver was handed, across the actor hop the saver closure makes.
private actor SavedPlans {
  private(set) var plans: [LeChefPlan] = []

  func append(_ plan: LeChefPlan) {
    plans.append(plan)
  }
}
