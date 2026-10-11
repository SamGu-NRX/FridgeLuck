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
    return try db.read { db in
      return try Ingredient.fetchAll(
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

  /// Fetch normalized aliases for a given ingredient ID.
  func aliases(for ingredientID: Int64) throws -> [String] {
    try db.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT alias
          FROM ingredient_aliases
          WHERE ingredient_id = ?
          ORDER BY alias
          """,
        arguments: [ingredientID]
      )
    }
  }

  // MARK: - Favorites

  /// Fetch ingredients marked as favorites, ordered by name.
  func fetchFavorites() throws -> [Ingredient] {
    try db.read { db in
      try Ingredient.fetchAll(
        db,
        sql: """
          SELECT i.*
          FROM ingredients i
          JOIN ingredient_favorites f ON f.ingredient_id = i.id
          ORDER BY i.name
          """
      )
    }
  }

  /// Toggle favorite status. Returns `true` if now favorited, `false` if unfavorited.
  @discardableResult
  func toggleFavorite(ingredientId: Int64) throws -> Bool {
    try db.write { db in
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM ingredient_favorites WHERE ingredient_id = ?)",
          arguments: [ingredientId]
        ) ?? false

      if exists {
        try db.execute(
          sql: "DELETE FROM ingredient_favorites WHERE ingredient_id = ?",
          arguments: [ingredientId]
        )
        return false
      } else {
        try db.execute(
          sql: "INSERT INTO ingredient_favorites (ingredient_id) VALUES (?)",
          arguments: [ingredientId]
        )
        return true
      }
    }
  }

  /// Check if an ingredient is favorited.
  func isFavorite(ingredientId: Int64) throws -> Bool {
    try db.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM ingredient_favorites WHERE ingredient_id = ?)",
        arguments: [ingredientId]
      ) ?? false
    }
  }

  // MARK: - Recently Used

  /// Fetch ingredients recently added to inventory, ordered by most recent.
  func fetchRecentlyUsed(limit: Int = 20) throws -> [Ingredient] {
    try db.read { db in
      try Ingredient.fetchAll(
        db,
        sql: """
          SELECT DISTINCT i.*
          FROM ingredients i
          JOIN inventory_events e ON e.ingredient_id = i.id
          WHERE e.event_type = 'addition'
          ORDER BY e.created_at DESC
          LIMIT ?
          """,
        arguments: [limit]
      )
    }
  }

  // MARK: - Common Ingredients

  /// Curated set of ~40 universally common grocery ingredients.
  private static let commonIngredientNames: [String] = [
    "egg", "milk", "chicken_breast", "rice", "onion", "garlic", "tomato",
    "potato", "olive_oil", "butter", "salt", "black_pepper", "bread",
    "cheese", "lettuce", "carrot", "bell_pepper", "pasta", "ground_beef",
    "salmon", "apple", "banana", "yogurt", "flour", "sugar", "lemon",
    "avocado", "broccoli", "spinach", "mushroom", "celery", "ginger",
    "soy_sauce", "honey", "oats", "corn", "cucumber", "cream",
    "chicken_thigh", "bacon",
  ]

  /// Fetch common everyday ingredients for default picker display.
  func fetchCommon(limit: Int = 40) throws -> [Ingredient] {
    let placeholders = Self.commonIngredientNames.map { _ in "?" }.joined(separator: ", ")
    let args = Self.commonIngredientNames.prefix(limit).map { $0 as any DatabaseValueConvertible }

    return try db.read { db in
      try Ingredient.fetchAll(
        db,
        sql: """
          SELECT i.*
          FROM ingredients i
          WHERE lower(i.name) IN (\(placeholders))
          ORDER BY i.name
          LIMIT ?
          """,
        arguments: StatementArguments(args + [limit as any DatabaseValueConvertible])
      )
    }
  }

  // MARK: - Grouped by Letter

  /// Fetch all ingredients grouped by first letter for sectioned display.
  func fetchAllGrouped() throws -> [(letter: String, ingredients: [Ingredient])] {
    let all = try fetchAll()
    let grouped = Dictionary(grouping: all) { ingredient -> String in
      let first = ingredient.displayName.prefix(1).uppercased()
      return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
    }

    return grouped.sorted { $0.key < $1.key }
      .map { (letter: $0.key, ingredients: $0.value) }
  }
}
