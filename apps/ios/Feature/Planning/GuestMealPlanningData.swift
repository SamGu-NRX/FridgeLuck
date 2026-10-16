import FLFeatureLogic
import Foundation
import GRDB

/// Recipes, stock and names the guest planner works from.
///
/// Recipes come from `PlanDataAdapter`, the same reader the weekly plan uses: legacy and
/// catalog recipes merged through the ingredient bridge, all already screened by the
/// household safety boundary. Catalog recipes carry negative IDs and unresolved catalog lines carry
/// negative sentinel ingredient IDs with no quantity.
struct GuestMealSnapshot: Sendable {
  /// Sorted by title.
  let recipes: [PlanCandidate]
  let lots: [InventoryLot]
  let ingredientNames: [Int64: String]
  /// Ingredients the household marks as always or usually on hand.
  let stapleIngredientIDs: Set<Int64>

  /// Two reads: the adapter's snapshot, then the lots for its ingredients. GRDB reads are not
  /// reentrant, so the lot query cannot join the adapter's transaction. Stock written between
  /// the reads shows up on the next reload.
  static func load(from queue: DatabaseQueue, now: Date) throws -> Self {
    let data = try PlanDataAdapter(dbQueue: queue, now: now).loadSnapshot()
    let blocked = Set(data.eaters.flatMap(\.blockedIngredientIDs))
    // The adapter has already screened every recipe; the allocator's eater filter runs here
    // too, as a second check on the exact stored ids: a required blocked line drops the
    // recipe, an optional one is never offered.
    let recipes = data.candidates.compactMap { candidate -> PlanCandidate? in
      guard !candidate.lines.contains(where: { $0.isRequired && blocked.contains($0.ingredientID) })
      else { return nil }
      return PlanCandidate(
        databaseID: candidate.databaseID, ref: candidate.ref, title: candidate.title,
        timeMinutes: candidate.timeMinutes, baseServings: candidate.baseServings,
        lines: candidate.lines.filter { !blocked.contains($0.ingredientID) })
    }
    .sorted {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame ? $0.databaseID < $1.databaseID : order == .orderedAscending
    }

    var names: [Int64: String] = [:]
    for line in recipes.flatMap(\.lines) where names[line.ingredientID] == nil {
      names[line.ingredientID] = line.name
    }
    let trackedIDs = names.keys.filter { $0 > 0 }
    let lots = try queue.read { db in
      try InventoryLot
        .filter(trackedIDs.contains(Column("ingredient_id")))
        .filter(Column("remaining_grams") != 0)
        .order(Column("acquired_at"), Column("id"))
        .fetchAll(db)
    }
    return Self(
      recipes: recipes, lots: lots, ingredientNames: names,
      stapleIngredientIDs: data.stapleIngredientIDs)
  }
}

/// A selected recipe line the gram planner cannot count.
struct GuestMealUncountedLine: Hashable, Sendable {
  enum Reason: Hashable, Sendable {
    /// The line has no amount in grams ("to taste", or a count with no weight).
    case noGrams
    /// The catalog ingredient has no match in the app's ingredient list, so stock can't cover it.
    case notTracked
  }

  let recipeTitle: String
  let ingredientName: String
  let reason: Reason
}

enum GuestMealMapping {
  struct Issue: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
  }

  struct MappedRecipe {
    /// Nil when none of the selected lines has a tracked ingredient and an amount in grams.
    let weighed: GuestMealPlanner.Recipe?
    let uncounted: [GuestMealUncountedLine]
  }

  /// Required lines plus the chosen optional ones. Lines without a tracked ingredient or a gram
  /// amount are returned separately instead of failing the whole menu, because many catalog
  /// lines ("salt, to taste") have no weight.
  static func recipe(_ candidate: PlanCandidate, optionalIDs: Set<Int64>) -> MappedRecipe {
    var weighed: [GuestMealPlanner.IngredientAmount] = []
    var uncounted: [GuestMealUncountedLine] = []
    for line in candidate.lines where line.isRequired || optionalIDs.contains(line.ingredientID) {
      if line.ingredientID <= 0 {
        uncounted.append(.init(recipeTitle: candidate.title, ingredientName: line.name, reason: .notTracked))
      } else if line.grams.isFinite, line.grams > 0 {
        weighed.append(.init(ingredientID: line.ingredientID, grams: line.grams))
      } else {
        uncounted.append(.init(recipeTitle: candidate.title, ingredientName: line.name, reason: .noGrams))
      }
    }
    return MappedRecipe(
      weighed: weighed.isEmpty
        ? nil
        : .init(recipeID: candidate.databaseID, baseServings: candidate.baseServings, ingredients: weighed),
      uncounted: uncounted)
  }

  static func lot(
    _ stored: InventoryLot, reviewedGrams: Double?, name: String
  ) throws -> GuestMealPlanner.InventoryLot {
    guard let id = stored.id, id > 0 else {
      throw Issue(message: "\(name) has a stock lot without a saved ID. Correct it in your fridge, then reload inventory.")
    }
    let grams = reviewedGrams ?? stored.remainingGrams
    guard stored.ingredientId > 0, grams.isFinite, grams >= 0 else {
      throw Issue(message: "\(name), lot \(id), needs a valid amount in grams. Review its stock below.")
    }
    if let expiry = stored.expiresAt, !expiry.timeIntervalSinceReferenceDate.isFinite {
      throw Issue(message: "\(name), lot \(id), has an invalid expiry. Correct it in your fridge, then reload inventory.")
    }
    // Confidence describes recognition, not a host's review of grams or ingredient form.
    return .init(
      lotID: id, ingredientID: stored.ingredientId, remainingGrams: grams,
      quantityStatus: reviewedGrams == nil ? .needsConfirmation : .confirmed,
      expiresAt: stored.expiresAt
    )
  }
}
