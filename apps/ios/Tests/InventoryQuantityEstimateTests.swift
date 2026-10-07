import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class InventoryQuantityEstimateTests: XCTestCase {
  func testPhotoEstimatedLotMarksItemEstimated() throws {
    let repository = InventoryRepository(db: try makeDatabase())
    try repository.addLot(
      ingredientId: 1, quantityGrams: 50, location: .fridge, confidenceScore: 0.9,
      source: .scan, quantityIsEstimate: true)

    XCTAssertEqual(try repository.fetchAllActiveItems().map(\.hasEstimatedQuantity), [true])
  }

  func testReviewedAmountIsNotEstimated() throws {
    let repository = InventoryRepository(db: try makeDatabase())
    try repository.addLot(
      ingredientId: 1, quantityGrams: 600, location: .fridge, confidenceScore: 0.9,
      source: .scan)

    XCTAssertEqual(try repository.fetchAllActiveItems().map(\.hasEstimatedQuantity), [false])
  }

  func testAnyEstimatedRemainingLotKeepsTotalEstimated() throws {
    let repository = InventoryRepository(db: try makeDatabase())
    try repository.addLot(
      ingredientId: 1, quantityGrams: 600, location: .fridge, confidenceScore: 1,
      source: .manual)
    try repository.addLot(
      ingredientId: 1, quantityGrams: 50, location: .fridge, confidenceScore: 0.9,
      source: .scan, quantityIsEstimate: true)

    let items = try repository.fetchAllActiveItems()
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.hasEstimatedQuantity, true)
  }

  func testConfirmingIdentityDoesNotTurnTheGuessIntoAMeasuredAmount() throws {
    let repository = InventoryRepository(db: try makeDatabase())
    try repository.addLot(
      ingredientId: 1, quantityGrams: 50, location: .fridge, confidenceScore: 0.4,
      source: .scan, quantityIsEstimate: true)
    let item = try XCTUnwrap(repository.fetchAllActiveItems().first)

    try repository.confirmActiveItem(id: item.id)

    let confirmed = try XCTUnwrap(repository.fetchAllActiveItems().first)
    XCTAssertEqual(confirmed.averageConfidenceScore, 1.0)
    XCTAssertTrue(confirmed.hasEstimatedQuantity)
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, typical_unit)
          VALUES (1, 'egg', 1.4, 0.13, 0.01, 0.1, '1 large (50g)')
          """
      )
    }
    return dbQueue
  }
}
