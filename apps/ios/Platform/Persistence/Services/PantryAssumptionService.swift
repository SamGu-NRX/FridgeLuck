import Foundation
import GRDB

final class PantryAssumptionService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func fetchAll() throws -> [PantryAssumption] {
    try db.read { db in
      try PantryAssumption
        .order(PantryAssumption.Columns.addedAt.desc)
        .fetchAll(db)
    }
  }

  func fetch(tier: PantryAssumption.PantryTier) throws -> [PantryAssumption] {
    try db.read { db in
      try PantryAssumption
        .filter(PantryAssumption.Columns.tier == tier.rawValue)
        .order(PantryAssumption.Columns.addedAt.desc)
        .fetchAll(db)
    }
  }

  func setAssumption(ingredientId: Int64, tier: PantryAssumption.PantryTier) throws {
    try db.write { db in
      let assumption = PantryAssumption(
        ingredientId: ingredientId,
        tier: tier,
        addedAt: Date()
      )
      try assumption.save(db)
    }
  }

  func setAssumptions(
    ingredientIDs: Set<Int64>,
    tier: PantryAssumption.PantryTier
  ) throws {
    guard !ingredientIDs.isEmpty else { return }

    try db.write { db in
      for ingredientId in ingredientIDs {
        let assumption = PantryAssumption(
          ingredientId: ingredientId,
          tier: tier,
          addedAt: Date()
        )
        try assumption.save(db)
      }
    }
  }

  func removeAssumption(ingredientId: Int64) throws {
    try db.write { db in
      _ = try PantryAssumption.deleteOne(db, key: ingredientId)
    }
  }

  func assumedAvailableIngredientIds() throws -> Set<Int64> {
    try db.read { db in
      let includedTiers = [
        PantryAssumption.PantryTier.alwaysHave.rawValue,
        PantryAssumption.PantryTier.usuallyHave.rawValue,
      ]
      let ids = try Int64.fetchAll(
        db,
        sql: """
          SELECT ingredient_id FROM pantry_assumptions
          WHERE tier IN (?, ?)
          """,
        arguments: StatementArguments(includedTiers)
      )
      return Set(ids)
    }
  }
}
