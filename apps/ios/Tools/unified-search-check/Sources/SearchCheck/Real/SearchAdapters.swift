import Foundation
import GRDB

// MARK: - Date tokens

/// Date-shaped search tokens shared by every adapter: journal meals are the
/// primary date-query target ("june 14", "2026-06"), and kitchen inventory
/// expiry dates are useful too. Tokens are folded lowercase so query folding
/// matches.
enum SearchDateTokens {
  private static let monthNames = [
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
  ]
  private static let monthAbbreviations = [
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec",
  ]

  /// Produces "yyyy-mm-dd yyyy-mm yyyy dd monthname monthabbrev" for a date
  /// in UTC, matching the UTC-relative date arithmetic the repository layer's
  /// own journal queries use.
  static func tokens(for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = components.year, let month = components.month, let day = components.day
    else { return "" }

    let monthIndex = month - 1
    var parts: [String] = []
    parts.append(String(format: "%04d-%02d-%02d", year, month, day))
    parts.append(String(format: "%04d-%02d", year, month))
    parts.append(String(format: "%04d", year))
    parts.append(String(format: "%02d", day))
    if monthIndex >= 0 && monthIndex < monthNames.count {
      parts.append(monthNames[monthIndex])
      parts.append(monthAbbreviations[monthIndex])
    }
    return parts.joined(separator: " ")
  }
}

// MARK: - Source bundle

/// The typed adapters over the base repositories. Adapters are read-only:
/// they never write to the source database, and they produce the full
/// document set a rebuild needs.
struct SearchSources: Sendable {
  let kitchen: KitchenSearchAdapter
  let recipes: RecipeSearchAdapter
  let journal: JournalSearchAdapter

  init(
    db: DatabaseQueue,
    ingredientRepository: IngredientRepository,
    inventoryRepository: InventoryRepository,
    recipeRepository: RecipeRepository,
    userDataRepository: UserDataRepository
  ) {
    kitchen = KitchenSearchAdapter(
      db: db,
      ingredientRepository: ingredientRepository,
      inventoryRepository: inventoryRepository
    )
    recipes = RecipeSearchAdapter(
      db: db,
      recipeRepository: recipeRepository
    )
    journal = JournalSearchAdapter(
      userDataRepository: userDataRepository
    )
  }

  func documents() throws -> [SearchDocument] {
    try kitchen.ingredientDocuments()
      + kitchen.inventoryDocuments()
      + recipes.documents()
      + journal.documents()
  }
}

// MARK: - Kitchen

/// Reads Kitchen records through the base repositories: the ingredient
/// catalog (IngredientRepository), its alias table, favorites, and the live
/// inventory items (InventoryRepository).
struct KitchenSearchAdapter: Sendable {
  // The service reuses these for hit resolution; adapters stay read-only.
  let databaseQueue: DatabaseQueue
  let ingredientRepository: IngredientRepository
  let inventoryRepository: InventoryRepository

  init(
    db: DatabaseQueue,
    ingredientRepository: IngredientRepository,
    inventoryRepository: InventoryRepository
  ) {
    self.databaseQueue = db
    self.ingredientRepository = ingredientRepository
    self.inventoryRepository = inventoryRepository
  }

  /// One document per catalog ingredient, keyed by the ingredient's own
  /// primary key. Aliases come from the alias table so known-item retrieval
  /// works by common name ("aubergine" style aliases).
  func ingredientDocuments() throws -> [SearchDocument] {
    let ingredients = try ingredientRepository.fetchAll()
    let favorites = Set(try ingredientRepository.fetchFavorites().compactMap(\.id))
    let aliasMap = try Self.aliasMap(db: databaseQueue)

    return ingredients.map { ingredient in
      let id = ingredient.id ?? 0
      var keywords = (aliasMap[id] ?? []).joined(separator: " ")
      if let category = ingredient.categoryLabel, !category.isEmpty {
        keywords += " " + category
      }
      if let description = ingredient.description, !description.isEmpty {
        keywords += " " + description
      }
      if favorites.contains(id) {
        keywords += " favorite starred"
      }
      let revision = SearchText.stableHash(ingredient.name + "|" + keywords)
      return SearchDocument(
        canonicalID: SearchCanonicalID(kind: .kitchenIngredient, rawID: String(id)),
        title: ingredient.displayName,
        subtitle: ingredient.categoryLabel,
        keywords: keywords,
        dateTokens: "",
        revision: revision
      )
    }
  }

  /// One document per live inventory item. The canonical ID matches
  /// `InventoryActiveItem.id` exactly: ingredient + storage location joined
  /// by "_" (location raw values contain no underscores, so parsing splits
  /// at the first "_").
  func inventoryDocuments() throws -> [SearchDocument] {
    let items = try inventoryRepository.fetchAllActiveItems()
    return items.map { item in
      let rawID = "\(item.ingredientId)_\(item.storageLocation.rawValue)"
      let grams = Int(item.totalRemainingGrams.rounded())
      let expiryTokens = item.earliestExpiresAt.map { SearchDateTokens.tokens(for: $0) } ?? ""
      let revision = item.lastUpdatedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
      return SearchDocument(
        canonicalID: SearchCanonicalID(kind: .kitchenInventory, rawID: rawID),
        title: item.ingredientName,
        subtitle: "\(item.storageLocation.rawValue) · \(grams) g in stock",
        keywords: "inventory in stock kitchen",
        dateTokens: expiryTokens,
        revision: revision
      )
    }
  }

  private static func aliasMap(db: DatabaseQueue) throws -> [Int64: [String]] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT ingredient_id, alias FROM ingredient_aliases")
      var map: [Int64: [String]] = [:]
      for row in rows {
        let id: Int64 = row["ingredient_id"]
        let alias: String = row["alias"]
        map[id, default: []].append(alias)
      }
      return map
    }
  }
}

// MARK: - Recipes

/// Reads recipes through RecipeRepository. The per-recipe ingredient name map
/// is read directly (read-only, one query) because the repository exposes
/// ingredients only per recipe and a rebuild must not issue N queries.
struct RecipeSearchAdapter: Sendable {
  let databaseQueue: DatabaseQueue
  let recipeRepository: RecipeRepository

  init(db: DatabaseQueue, recipeRepository: RecipeRepository) {
    self.databaseQueue = db
    self.recipeRepository = recipeRepository
  }

  func documents() throws -> [SearchDocument] {
    // No fixed cap: a year of AI-generated recipes must all be findable.
    let recipes = try recipeRepository.fetchAllRecipes(limit: 1_000_000)
    guard !recipes.isEmpty else { return [] }
    let ingredientNames = try Self.ingredientNamesByRecipe(db: databaseQueue)

    return recipes.compactMap { recipe in
      guard let id = recipe.id else { return nil }
      let names = ingredientNames[id] ?? []
      let tags = recipe.recipeTags.labels.joined(separator: " ")
      let revision =
        (recipe.createdAt.map { Int64($0.timeIntervalSince1970) } ?? 0)
        &+ SearchText.stableHash(recipe.title)
      return SearchDocument(
        canonicalID: SearchCanonicalID(kind: .recipe, rawID: String(id)),
        title: recipe.title,
        subtitle: "\(recipe.timeMinutes) min · \(recipe.servings) servings",
        keywords: (names + [tags]).joined(separator: " "),
        dateTokens: recipe.createdAt.map { SearchDateTokens.tokens(for: $0) } ?? "",
        revision: revision
      )
    }
  }

  private static func ingredientNamesByRecipe(db: DatabaseQueue) throws -> [Int64: [String]] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ri.recipe_id, i.name
          FROM recipe_ingredients ri
          JOIN ingredients i ON i.id = ri.ingredient_id
          """)
      var map: [Int64: [String]] = [:]
      for row in rows {
        let id: Int64 = row["recipe_id"]
        let name: String = row["name"]
        map[id, default: []].append(name)
      }
      return map
    }
  }
}

// MARK: - Journal

/// Reads logged meals through UserDataRepository.cookingJournal(), which
/// already folds in the frozen nutrition snapshots. Each cooking_history row
/// is one document keyed by its own primary key.
struct JournalSearchAdapter: Sendable {
  private let userDataRepository: UserDataRepository

  init(userDataRepository: UserDataRepository) {
    self.userDataRepository = userDataRepository
  }

  func documents() throws -> [SearchDocument] {
    let entries = try userDataRepository.cookingJournal()
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, MMM d, yyyy"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC") ?? .current

    return entries.map { entry in
      let ratingPart = entry.rating.map { " · rated \($0)" } ?? ""
      let dateLabel = formatter.string(from: entry.cookedAt)
      let revision =
        Int64(entry.cookedAt.timeIntervalSince1970) * 10
        + Int64(entry.rating ?? 0)
      return SearchDocument(
        canonicalID: SearchCanonicalID(kind: .journal, rawID: String(entry.id)),
        title: entry.recipe.title,
        subtitle: "Cooked \(dateLabel)\(ratingPart)",
        keywords: "journal meal logged",
        dateTokens: SearchDateTokens.tokens(for: entry.cookedAt),
        revision: revision
      )
    }
  }
}
