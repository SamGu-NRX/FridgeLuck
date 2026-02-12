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
    let lowered = query.lowercased()
    let like = "%\(lowered)%"
    let prefix = "\(lowered)%"
    try db.read { db in
      try Ingredient.fetchAll(
        db,
        sql: """
            SELECT DISTINCT i.*
            FROM ingredients i
            LEFT JOIN ingredient_aliases a ON a.ingredient_id = i.id
            WHERE lower(i.name) LIKE ?
               OR lower(COALESCE(i.description, '')) LIKE ?
               OR lower(COALESCE(i.notes, '')) LIKE ?
               OR lower(COALESCE(a.alias, '')) LIKE ?
            ORDER BY
              CASE
                WHEN lower(i.name) = ? THEN 0
                WHEN lower(i.name) LIKE ? THEN 1
                ELSE 2
              END,
              i.name
            LIMIT ?
          """,
        arguments: [like, like, like, like, lowered, prefix, limit]
      )
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
