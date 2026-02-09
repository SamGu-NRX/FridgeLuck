import Foundation
import GRDB

/// Repository for ingredient queries.
final class IngredientRepository: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// Fetch a single ingredient by ID.
  func fetch(id: Int64) throws -> Ingredient? {
    try db.read { db in
      try Ingredient.fetchOne(db, key: id)
    }
  }

  /// Fetch multiple ingredients by IDs.
  func fetch(ids: Set<Int64>) throws -> [Ingredient] {
    try db.read { db in
      try Ingredient.fetchAll(db, keys: Array(ids))
    }
  }

  /// Search ingredients by name (for manual add).
  func search(query: String, limit: Int = 20) throws -> [Ingredient] {
    try db.read { db in
      try Ingredient
        .filter(Ingredient.Columns.name.like("%\(query)%"))
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Fetch all ingredients (for browsing).
  func fetchAll() throws -> [Ingredient] {
    try db.read { db in
      try Ingredient.order(Ingredient.Columns.name).fetchAll(db)
    }
  }

  /// Total number of ingredients in the database.
  func count() throws -> Int {
    try db.read { db in
      try Ingredient.fetchCount(db)
    }
  }
}
