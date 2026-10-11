import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// A scan-review session can be revisited: back from recipes, correct an item, search again.
/// Intake must make the Kitchen match the latest confirmation without duplicating food.
final class ScanIntakeReconciliationTests: XCTestCase {
  private let tomato: Int64 = 1
  private let pepper: Int64 = 2
  private let egg: Int64 = 3

  func testRepeatSearchWithSameConfirmationAddsNothingNew() throws {
    let (db, intake, inventory) = try makeServices()
    let detections = [detection(tomato)]

    try intake.ingestConfirmedScan(
      detections: detections, confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    let second = try intake.ingestConfirmedScan(
      detections: detections, confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(second.lotsAdded, 0)
    XCTAssertEqual(try activeIngredientIDs(inventory), [tomato])
    XCTAssertEqual(try lotCount(db), 1)
  }

  func testCorrectionOnRevisitReplacesTheUntouchedLot() throws {
    let (_, intake, inventory) = try makeServices()
    let tomatoDetection = detection(tomato)

    try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    let revisit = try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [pepper],
      selectedIngredientByDetection: [tomatoDetection.id: pepper], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(revisit.lotsAdded, 1)
    XCTAssertEqual(revisit.lotsRetired, 1)
    XCTAssertEqual(try activeIngredientIDs(inventory), [pepper])
  }

  func testCorrectingBackRestoresTheOriginalFood() throws {
    let (db, intake, inventory) = try makeServices()
    let tomatoDetection = detection(tomato)
    try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [pepper],
      selectedIngredientByDetection: [tomatoDetection.id: pepper], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    let third = try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(third.lotsRestored, 1)
    XCTAssertEqual(third.lotsRetired, 1)
    XCTAssertEqual(try activeIngredientIDs(inventory), [tomato])
    XCTAssertEqual(try lotCount(db), 2)
  }

  func testFoodRemovedInKitchenIsNotRestoredByReview() throws {
    let (_, intake, inventory) = try makeServices()
    try intake.ingestConfirmedScan(
      detections: [detection(egg)], confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    let item = try XCTUnwrap(inventory.fetchAllActiveItems().first)
    try inventory.removeActiveItem(id: item.id)

    let revisit = try intake.ingestConfirmedScan(
      detections: [detection(egg)], confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(revisit.lotsRestored, 0)
    XCTAssertEqual(try activeIngredientIDs(inventory), [])
  }

  func testAddedItemOnRevisitIsSaved() throws {
    let (_, intake, inventory) = try makeServices()
    let tomatoDetection = detection(tomato)

    try intake.ingestConfirmedScan(
      detections: [tomatoDetection], confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    try intake.ingestConfirmedScan(
      detections: [tomatoDetection, detection(egg)], confirmedIngredientIDs: [tomato, egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(try activeIngredientIDs(inventory), [tomato, egg])
  }

  func testRevisitNeverReaddsFoodAlreadyCookedFrom() throws {
    let (db, intake, inventory) = try makeServices()
    let detections = [detection(egg)]
    try intake.ingestConfirmedScan(
      detections: detections, confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    try consumeEverything(egg, db: db)

    let revisit = try intake.ingestConfirmedScan(
      detections: detections, confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(revisit.lotsAdded, 0)
    XCTAssertEqual(try activeIngredientIDs(inventory), [])
  }

  func testUnconfirmingAPartlyCookedLotKeepsWhatIsLeft() throws {
    let (db, intake, inventory) = try makeServices()
    try intake.ingestConfirmedScan(
      detections: [detection(egg)], confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])
    try consumeHalf(egg, db: db)

    let revisit = try intake.ingestConfirmedScan(
      detections: [detection(egg)], confirmedIngredientIDs: [],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(revisit.lotsRetired, 0)
    XCTAssertEqual(try activeIngredientIDs(inventory), [egg])
  }

  func testSeparateSessionsDoNotTouchEachOther() throws {
    let (_, intake, inventory) = try makeServices()
    try intake.ingestConfirmedScan(
      detections: [detection(tomato)], confirmedIngredientIDs: [tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    try intake.ingestConfirmedScan(
      detections: [detection(egg)], confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [:], sourceRef: "s2",
      location: .inferredFromIngredient, preserving: [])

    XCTAssertEqual(try activeIngredientIDs(inventory), [tomato, egg])
  }

  func testIntakeIsAllOrNothing() throws {
    let (db, intake, _) = try makeServices()
    // An ingredient ID with no ingredients row violates the lot foreign key mid-intake.
    XCTAssertThrowsError(
      try intake.ingestConfirmedScan(
        detections: [detection(tomato), detection(999)], confirmedIngredientIDs: [tomato, 999],
        selectedIngredientByDetection: [:], sourceRef: "s1",
        location: .inferredFromIngredient, preserving: []))

    XCTAssertEqual(try lotCount(db), 0)
  }

  func testPreservedIngredientsAreLeftExactlyAsTheyAre() throws {
    let (db, intake, inventory) = try makeServices()
    try intake.ingestConfirmedScan(
      detections: [detection(tomato), detection(egg)], confirmedIngredientIDs: [tomato, egg],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    // Neither confirmed: the tomato is retired, the preserved egg is not, and the preserved
    // pepper is not added even though it is confirmed.
    let revisit = try intake.ingestConfirmedScan(
      detections: [detection(pepper)], confirmedIngredientIDs: [pepper],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [egg, pepper])

    XCTAssertEqual(revisit.lotsRetired, 1)
    XCTAssertEqual(revisit.lotsAdded, 0)
    XCTAssertEqual(try activeIngredientIDs(inventory), [egg])
    XCTAssertEqual(try lotCount(db), 2)
  }

  func testPhotographedLocationMissingAnIngredientThrowsAndWritesNothing() throws {
    let (db, intake, _) = try makeServices()

    XCTAssertThrowsError(
      try intake.ingestConfirmedScan(
        detections: [detection(tomato), detection(egg)], confirmedIngredientIDs: [tomato, egg],
        selectedIngredientByDetection: [:], sourceRef: "s1",
        location: .photographed(byIngredient: [tomato: .fridge]), preserving: [])
    ) { error in
      XCTAssertEqual(error as? IntakeError, .missingLocation(ingredientID: egg))
    }
    XCTAssertEqual(try lotCount(db), 0)
  }

  func testStoredAmountIsTheEstimateTheReviewShowed() throws {
    let (_, intake, inventory) = try makeServices()
    let eggDetection = Detection(
      ingredientId: egg, label: "Egg", confidence: 0.9, source: .vision, originalVisionLabel: "egg")
    let garlicDetection = Detection(
      ingredientId: tomato, label: "Garlic", confidence: 0.9, source: .vision,
      originalVisionLabel: "garlic")

    try intake.ingestConfirmedScan(
      detections: [eggDetection, garlicDetection], confirmedIngredientIDs: [egg, tomato],
      selectedIngredientByDetection: [:], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    let grams = Dictionary(
      uniqueKeysWithValues: try inventory.fetchAllActiveItems().map {
        ($0.ingredientId, $0.totalRemainingGrams)
      })
    XCTAssertEqual(grams[egg], InventoryIntakeService.estimateGrams(forName: "Egg"))
    XCTAssertEqual(grams[egg], 50)
    // No floor: a 20 g garlic estimate stays 20 g.
    XCTAssertEqual(grams[tomato], InventoryIntakeService.estimateGrams(forName: "Garlic"))
    XCTAssertEqual(grams[tomato], 20)
  }

  func testCorrectedDetectionIsEstimatedFromTheChosenIngredient() throws {
    let (_, intake, inventory) = try makeServices()
    // Vision said "Garlic" (20 g estimate); the user corrected it to egg.
    let detection = Detection(
      ingredientId: tomato, label: "Garlic", confidence: 0.6, source: .vision,
      originalVisionLabel: "garlic")

    try intake.ingestConfirmedScan(
      detections: [detection], confirmedIngredientIDs: [egg],
      selectedIngredientByDetection: [detection.id: egg], sourceRef: "s1",
      location: .inferredFromIngredient, preserving: [])

    let item = try XCTUnwrap(inventory.fetchAllActiveItems().first)
    XCTAssertEqual(item.ingredientId, egg)
    XCTAssertEqual(item.totalRemainingGrams, 50)
  }

  // MARK: - Helpers

  /// Cooks through the real consumption path so consume events exist, as after a meal.
  private func consumeEverything(_ ingredientID: Int64, db: DatabaseQueue) throws {
    try cook(ingredientID, grams: 10_000, db: db)
  }

  private func consumeHalf(_ ingredientID: Int64, db: DatabaseQueue) throws {
    let remaining = try db.read {
      try Double.fetchOne($0, sql: "SELECT SUM(remaining_grams) FROM inventory_lots") ?? 0
    }
    try cook(ingredientID, grams: remaining / 2, db: db)
  }

  private func cook(_ ingredientID: Int64, grams: Double, db: DatabaseQueue) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (100, 'Test Dish', 5, 1, 'Cook.');
          DELETE FROM recipe_ingredients WHERE recipe_id = 100;
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (100, ?, 1, ?, 'some');
          """,
        arguments: [ingredientID, grams]
      )
    }
    _ = try InventoryRepository(db: db).applyConsumption(recipeId: 100, servingsConsumed: 1)
  }

  private func detection(_ ingredientID: Int64) -> Detection {
    Detection(
      ingredientId: ingredientID, label: "item \(ingredientID)", confidence: 0.9,
      source: .vision, originalVisionLabel: "item_\(ingredientID)")
  }

  private func activeIngredientIDs(_ inventory: InventoryRepository) throws -> [Int64] {
    try inventory.fetchAllActiveItems().map(\.ingredientId).sorted()
  }

  private func lotCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM inventory_lots") ?? 0 }
  }

  private func makeServices() throws -> (DatabaseQueue, InventoryIntakeService, InventoryRepository)
  {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, typical_unit) VALUES
            (1, 'tomato', 0.18, 0.01, 0.04, 0, '1 medium (120g)'),
            (2, 'bell_pepper', 0.2, 0.01, 0.05, 0, '1 medium (120g)'),
            (3, 'egg', 1.4, 0.13, 0.01, 0.1, '1 large (50g)')
          """
      )
    }
    let inventory = InventoryRepository(db: db)
    let intake = InventoryIntakeService(
      ingredientRepository: IngredientRepository(db: db), inventoryRepository: inventory)
    return (db, intake, inventory)
  }
}
