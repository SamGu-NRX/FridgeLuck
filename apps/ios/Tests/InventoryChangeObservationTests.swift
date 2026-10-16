import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class InventoryChangeObservationTests: XCTestCase {
  func testObserverFiresForInTransactionInventoryWrite() throws {
    let dbQueue = try makeDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let changed = expectation(description: "inventory change observed")
    changed.assertForOverFulfill = false

    let observer = repository.observeInventoryChanges { changed.fulfill() }

    // The same kind of raw, transaction-scoped write MealLogService performs, which never
    // posts the inventoryDidChange notification.
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams)
          VALUES (1, 100, 100)
          """
      )
    }

    wait(for: [changed], timeout: 2)
    observer.cancel()
  }

  func testObserverIgnoresWritesOutsideInventory() throws {
    let dbQueue = try makeDatabase()
    let repository = InventoryRepository(db: dbQueue)
    let changed = expectation(description: "no inventory change")
    changed.isInverted = true

    let observer = repository.observeInventoryChanges { changed.fulfill() }

    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO streaks (date, meals_cooked) VALUES ('2026-10-07', 1)"
      )
    }

    wait(for: [changed], timeout: 0.5)
    observer.cancel()
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (1, 'test egg', 1.4, 0.13, 0.01, 0.1)
          """
      )
    }
    return dbQueue
  }
}
