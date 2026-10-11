import Foundation
import GRDB

// MARK: - Planning stock read model

/// Read-only lot row for the planning adapter: the weekly planner consumes
/// per-lot grams with an explicit estimate flag, so no aggregation happens
/// here. Owned by the weekly-plan feature — `InventoryRepository` is a
/// reserved core file and gains nothing for planning.
struct WeeklyPlanStockLot: Sendable {
  let ingredientId: Int64
  let remainingGrams: Double
  /// True when the amount is a photo-intake guess the user has not confirmed.
  let quantityIsEstimate: Bool
  let expiresAt: Date?
}

// MARK: - Reader

/// Reads the remaining inventory lots for planning. Read-only by policy —
/// planning never reserves or consumes stock; consumption stays with
/// `InventoryRepository.applyConsumption`. Shares the app's database queue
/// (the same one every service reads) but adds no writer of its own.
struct WeeklyPlanStockReader: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// Every remaining lot with its estimate flag and expiry, stable-ordered
  /// (ingredient, expiry, id) so input building is deterministic.
  func fetchPlanningLots() throws -> [WeeklyPlanStockLot] {
    try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_id, remaining_grams, quantity_is_estimate, expires_at
          FROM inventory_lots
          WHERE remaining_grams > 0
          ORDER BY ingredient_id ASC, datetime(expires_at) ASC, id ASC
          """
      ).compactMap { row in
        guard
          let ingredientId: Int64 = row["ingredient_id"],
          let remainingGrams: Double = row["remaining_grams"]
        else { return nil }
        return WeeklyPlanStockLot(
          ingredientId: ingredientId,
          remainingGrams: remainingGrams,
          quantityIsEstimate: (row["quantity_is_estimate"] as Bool?) ?? false,
          expiresAt: row["expires_at"]
        )
      }
    }
  }
}
