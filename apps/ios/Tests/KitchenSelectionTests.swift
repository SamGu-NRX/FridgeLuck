import GRDB
import XCTest

@testable import FridgeLuck

/// Cooking away the last item of the selected location removes its chip. The filter must fall
/// back to All on the next refresh instead of hiding everything else.
@MainActor
final class KitchenSelectionTests: XCTestCase {
  func testSelectionKeepsALocationThatStillHasItems() {
    XCTAssertEqual(KitchenLocationOrder.selection(.unknown, counts: [.unknown: 1]), .unknown)
  }

  func testSelectionFallsBackToAllWhenItsLocationIsEmpty() {
    XCTAssertNil(KitchenLocationOrder.selection(.unknown, counts: [.fridge: 2]))
    XCTAssertNil(KitchenLocationOrder.selection(.unknown, counts: [.fridge: 2, .unknown: 0]))
    XCTAssertNil(KitchenLocationOrder.selection(nil, counts: [.fridge: 2]))
  }

  func testDepletingTheSelectedLocationResetsTheFilterAfterRefresh() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'black beans', 132, 8.9, 23.7, 0.5),
            (2, 'olive oil', 884, 0, 0, 100);
          INSERT INTO inventory_lots
            (ingredient_id, quantity_grams, remaining_grams, storage_location)
          VALUES (1, 180, 180, 'fridge'), (2, 30, 30, 'unknown');
          """
      )
    }
    let viewModel = KitchenViewModel(
      inventoryRepository: InventoryRepository(db: db),
      pantryAssumptionService: PantryAssumptionService(db: db)
    )
    await viewModel.load()
    viewModel.selectedLocation = .unknown
    XCTAssertEqual(viewModel.filteredItems.map(\.ingredientName), ["olive oil"])

    // Cooking uses up the olive oil; the inventory observer refreshes the Kitchen.
    try await db.write { db in
      try db.execute(sql: "UPDATE inventory_lots SET remaining_grams = 0 WHERE ingredient_id = 2")
    }
    try await waitUntil { viewModel.allItems.count == 1 && !viewModel.isLoading }

    XCTAssertNil(viewModel.selectedLocation)
    XCTAssertEqual(viewModel.filteredItems.map(\.ingredientName), ["black beans"])
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), "Kitchen did not refresh after the inventory change")
  }
}
