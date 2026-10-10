import Foundation
import GRDB

// MARK: - Resolved targets

/// A live, just-validated record behind a search hit. Only values produced by
/// `SearchHitResolving.resolve` may be opened or mutated; a nil result means
/// the indexed record no longer exists in the source database.
enum SearchResolvedTarget: Sendable {
  case kitchenIngredient(Ingredient)
  case kitchenInventory(KitchenInventoryDetail)
  case recipe(Recipe)
  case journal(JournalEntryDetail)
}

/// Live kitchen inventory state for a resolved hit (read-only snapshot).
struct KitchenInventoryDetail: Sendable, Equatable {
  let ingredientId: Int64
  let ingredientName: String
  let storageLocation: InventoryStorageLocation
  let totalRemainingGrams: Double
  let earliestExpiresAt: Date?
}

/// Live journal state for a resolved hit (read-only snapshot).
struct JournalEntryDetail: Sendable, Equatable {
  let historyId: Int64
  let recipeId: Int64
  let recipeTitle: String
  let cookedAt: Date
  let rating: Int?
  let servingsConsumed: Int?
}

// MARK: - Resolution

/// Revalidates a search hit against the source repositories immediately
/// before it is surfaced or acted on. Canonical IDs alone are never trusted.
protocol SearchHitResolving: Sendable {
  /// Returns the live record for the hit, or nil when the record was deleted
  /// (or the ID is malformed).
  func resolve(_ hit: SearchHit) throws -> SearchResolvedTarget?

  /// The live revision stamp for the record, when the kind carries a
  /// timestamped revision (inventory items, journal rows). nil means the kind
  /// has no independently checkable live revision; existence is still
  /// validated, and content staleness is healed by epoch-triggered rebuilds.
  func liveRevision(for hit: SearchHit) throws -> Int64?
}

/// Dispatches resolution by kind to read-only source reads.
struct CompositeSearchHitResolver: SearchHitResolving {
  private let db: DatabaseQueue
  private let ingredientRepository: IngredientRepository
  private let inventoryRepository: InventoryRepository
  private let recipeRepository: RecipeRepository

  init(
    db: DatabaseQueue,
    ingredientRepository: IngredientRepository,
    inventoryRepository: InventoryRepository,
    recipeRepository: RecipeRepository
  ) {
    self.db = db
    self.ingredientRepository = ingredientRepository
    self.inventoryRepository = inventoryRepository
    self.recipeRepository = recipeRepository
  }

  func resolve(_ hit: SearchHit) throws -> SearchResolvedTarget? {
    switch hit.canonicalID.kind {
    case .kitchenIngredient:
      guard let id = Int64(hit.canonicalID.rawID) else { return nil }
      guard let ingredient = try ingredientRepository.fetch(id: id) else { return nil }
      return .kitchenIngredient(ingredient)
    case .kitchenInventory:
      guard let detail = try resolveInventory(rawID: hit.canonicalID.rawID) else { return nil }
      return .kitchenInventory(detail)
    case .recipe:
      guard let id = Int64(hit.canonicalID.rawID) else { return nil }
      guard let recipe = try recipeRepository.fetchRecipe(id: id) else { return nil }
      return .recipe(recipe)
    case .journal:
      guard let detail = try resolveJournal(rawID: hit.canonicalID.rawID) else { return nil }
      return .journal(detail)
    }
  }

  func liveRevision(for hit: SearchHit) throws -> Int64? {
    switch hit.canonicalID.kind {
    case .kitchenInventory:
      guard let separator = hit.canonicalID.rawID.firstIndex(of: "_") else { return nil }
      guard let ingredientId = Int64(hit.canonicalID.rawID[hit.canonicalID.rawID.startIndex..<separator])
      else { return nil }
      return try? liveInventoryRevision(ingredientId: ingredientId)
    case .journal:
      guard let historyId = Int64(hit.canonicalID.rawID) else { return nil }
      return try resolveJournalRevision(historyId: historyId)
    case .kitchenIngredient, .recipe:
      return nil
    }
  }

  private func resolveInventory(rawID: String) throws -> KitchenInventoryDetail? {
    // Matches InventoryActiveItem.id: "ingredientId_location" (location raw
    // values never contain "_", so the split is unambiguous).
    guard let separator = rawID.firstIndex(of: "_") else { return nil }
    let idPart = rawID[rawID.startIndex..<separator]
    let locationPart = String(rawID[rawID.index(after: separator)...])
    guard let ingredientId = Int64(idPart),
      let location = InventoryStorageLocation(rawValue: locationPart)
    else { return nil }

    let items = try inventoryRepository.fetchAllActiveItems()
    guard
      let item = items.first(where: {
        $0.ingredientId == ingredientId && $0.storageLocation == location
      })
    else { return nil }

    return KitchenInventoryDetail(
      ingredientId: item.ingredientId,
      ingredientName: item.ingredientName,
      storageLocation: item.storageLocation,
      totalRemainingGrams: item.totalRemainingGrams,
      earliestExpiresAt: item.earliestExpiresAt
    )
  }

  private func liveInventoryRevision(ingredientId: Int64) throws -> Int64 {
    try db.read { db in
      let row = try Row.fetchOne(
        db,
        sql: "SELECT last_updated_at FROM inventory_items WHERE ingredient_id = ?",
        arguments: [ingredientId])
      let date: Date? = row?["last_updated_at"]
      return date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }
  }

  private func resolveJournal(rawID: String) throws -> JournalEntryDetail? {
    guard let historyId = Int64(rawID) else { return nil }
    return try resolveJournalRow(historyId: historyId)
  }

  private func resolveJournalRow(historyId: Int64) throws -> JournalEntryDetail? {
    try db.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT ch.cooked_at, ch.rating, ch.servings_consumed,
                 ch.recipe_id, r.title
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          WHERE ch.id = ?
          """,
        arguments: [historyId])
      guard let row else { return nil }
      let cookedAt: Date? = row["cooked_at"]
      guard let cookedAt else { return nil }
      let rating: Int? = row["rating"]
      let servingsConsumed: Int? = row["servings_consumed"]
      return JournalEntryDetail(
        historyId: historyId,
        recipeId: row["recipe_id"],
        recipeTitle: row["title"],
        cookedAt: cookedAt,
        rating: rating,
        servingsConsumed: servingsConsumed
      )
    }
  }

  private func resolveJournalRevision(historyId: Int64) throws -> Int64? {
    guard let detail = try resolveJournalRow(historyId: historyId) else { return nil }
    return Int64(detail.cookedAt.timeIntervalSince1970) * 10 + Int64(detail.rating ?? 0)
  }
}

// MARK: - Engine

/// Executes queries against the search index and revalidates every hit
/// against the source repositories before returning it. A stale index hit
/// whose record was deleted is dropped from the results and repaired out of
/// the index, so callers can never open or mutate a deleted record through
/// search.
final class SearchEngine: @unchecked Sendable {
  static let defaultLimit = 30

  private let store: SearchIndexStore
  private let resolver: any SearchHitResolving

  init(store: SearchIndexStore, resolver: any SearchHitResolving) {
    self.store = store
    self.resolver = resolver
  }

  /// Runs a query. Throws `CancellationError` when the surrounding task is
  /// cancelled; the engine checks between every stage so rapid re-queries
  /// (typing) abandon obsolete work instead of racing it.
  func search(
    _ rawQuery: String,
    kinds: Set<SearchRecordKind>? = nil,
    limit: Int = SearchEngine.defaultLimit
  ) throws -> [SearchHit] {
    try Task.checkCancellation()

    let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let capped = String(trimmed.prefix(SearchText.maxQueryLength))
    let tokens = SearchText.tokens(in: capped)
    guard let matchExpression = Self.matchExpression(for: tokens) else { return [] }

    // Over-fetch so resolution can drop deleted records without starving the
    // requested limit.
    let rawHits = try store.fetchHits(
      match: matchExpression,
      kinds: kinds,
      limit: max(limit * 3, limit + 10))

    try Task.checkCancellation()

    var kept: [SearchHit] = []
    for (index, hit) in rawHits.enumerated() {
      if index % 8 == 0 {
        try Task.checkCancellation()
      }
      // Existence revalidation before the hit is allowed to surface.
      guard try resolver.resolve(hit) != nil else {
        try? store.remove(canonicalID: hit.canonicalID)
        continue
      }
      // Refresh the visible revision to the live value where the kind carries
      // one; index documents themselves are healed by the next
      // epoch-triggered rebuild.
      if let liveRevision = try resolver.liveRevision(for: hit) {
        kept.append(hit.withRevision(liveRevision))
      } else {
        kept.append(hit)
      }
      if kept.count >= limit { break }
    }

    return Self.rank(kept, query: capped)
  }

  // MARK: - Matching

  /// Builds an FTS5 MATCH expression: every query token is an implicit-AND
  /// prefix term, so "chick" matches "chicken breast" and "soy sauce" matches
  /// the compound "soy_sauce" (the tokenizer splits on "_"). Tokens are
  /// quoted so FTS syntax characters in user input stay literal.
  static func matchExpression(for tokens: [String]) -> String? {
    guard !tokens.isEmpty else { return nil }
    return tokens
      .map { token in
        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
      }
      .joined(separator: " ")
  }

  /// Deterministic display ordering: exact title matches first, then FTS5
  /// rank, then kind priority, then canonical ID — stable across runs.
  static func rank(_ hits: [SearchHit], query: String) -> [SearchHit] {
    let foldedQuery = SearchText.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    return hits.sorted { lhs, rhs in
      let lhsExact = SearchText.folded(lhs.title) == foldedQuery
      let rhsExact = SearchText.folded(rhs.title) == foldedQuery
      if lhsExact != rhsExact { return lhsExact }
      if lhs.rankScore != rhs.rankScore { return lhs.rankScore < rhs.rankScore }
      if lhs.canonicalID.kind != rhs.canonicalID.kind {
        return lhs.canonicalID.kind < rhs.canonicalID.kind
      }
      return lhs.canonicalID.description < rhs.canonicalID.description
    }
  }
}

extension SearchHit {
  /// Returns a copy stamped with the live revision.
  func withRevision(_ revision: Int64) -> SearchHit {
    SearchHit(
      canonicalID: canonicalID,
      title: title,
      subtitle: subtitle,
      revision: revision,
      rankScore: rankScore
    )
  }
}
