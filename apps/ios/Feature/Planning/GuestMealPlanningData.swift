import FLFeatureLogic
import Foundation
import GRDB

/// Recipes, stock and names the guest planner works from.
///
/// Recipes come from `PlanDataAdapter`, the same reader the weekly plan uses: legacy and
/// catalog recipes merged through the ingredient bridge, catalog rows already screened by the
/// household safety gate. Catalog recipes carry negative IDs and unresolved catalog lines carry
/// negative sentinel ingredient IDs with no quantity. Web-scraped legacy recipes are left out
/// (`scrapedLegacyRecipeIDs`), and every line carries a readable ingredient name.
struct GuestMealSnapshot: Sendable {
  /// Sorted by title.
  let recipes: [PlanCandidate]
  let lots: [InventoryLot]
  let ingredientNames: [Int64: String]
  /// Ingredients the household marks as always or usually on hand.
  let stapleIngredientIDs: Set<Int64>

  /// Two reads: the adapter's snapshot, then names, scraped recipe IDs and lots. GRDB reads
  /// are not reentrant, so the second read cannot join the adapter's transaction. Stock
  /// written between the reads shows up on the next reload.
  static func load(from queue: DatabaseQueue, now: Date) throws -> Self {
    let data = try PlanDataAdapter(dbQueue: queue, now: now).loadSnapshot()
    let blocked = Set(data.eaters.flatMap(\.blockedIngredientIDs))
    return try queue.read { db in
      let scraped = try scrapedLegacyRecipeIDs(db)
      // The adapter leaves legacy allergen screening to the weekly allocator, so apply the
      // same eater filter here: a required blocked line drops the recipe, an optional one is
      // never offered.
      let screened = data.candidates.filter { candidate in
        !scraped.contains(candidate.databaseID)
          && !candidate.lines.contains { $0.isRequired && blocked.contains($0.ingredientID) }
      }
      let names = try readableNames(for: screened, db)
      let recipes = screened.map { candidate in
        PlanCandidate(
          databaseID: candidate.databaseID, ref: candidate.ref, title: candidate.title,
          timeMinutes: candidate.timeMinutes, baseServings: candidate.baseServings,
          lines: candidate.lines.filter { !blocked.contains($0.ingredientID) }.map { line in
            PlanCandidateLine(
              ingredientID: line.ingredientID, name: names[line.ingredientID] ?? line.name,
              grams: line.grams, isRequired: line.isRequired,
              bridgedIngredientIDs: line.bridgedIngredientIDs)
          })
      }
      .sorted {
        let order = $0.title.localizedStandardCompare($1.title)
        return order == .orderedSame ? $0.databaseID < $1.databaseID : order == .orderedAscending
      }

      let usedIDs = Set(recipes.flatMap { $0.lines.map(\.ingredientID) })
      let lots = try InventoryLot
        .filter(usedIDs.filter { $0 > 0 }.contains(Column("ingredient_id")))
        .filter(Column("remaining_grams") != 0)
        .order(Column("acquired_at"), Column("id"))
        .fetchAll(db)
      return Self(
        recipes: recipes, lots: lots, ingredientNames: names.filter { usedIDs.contains($0.key) },
        stapleIngredientIDs: data.stapleIngredientIDs)
    }
  }

  /// Bundled legacy recipes that carry a "Source:" line: the 141 web-scraped rows of
  /// data.json. The scraper (scripts/recipe_scraper, `_resolve_ingredient_id`) kept only the
  /// ingredients it could match to data.json's 50-ingredient list and dropped the rest, so
  /// these bills are partial: "Air fryer tuna pasta bake" (recipe 27) stores sesame oil, green
  /// onion, garlic and chilli flakes, with no tuna, pasta, tomato or mozzarella. Scaling such
  /// a bill gives a grocery list that is wrong for the dish, so the guest planner leaves these
  /// recipes out; the catalog's recipes and the 25 hand-written legacy rows remain.
  static func scrapedLegacyRecipeIDs(_ db: Database) throws -> Set<Int64> {
    let rows = try Row.fetchAll(
      db, sql: "SELECT id, instructions FROM recipes WHERE source = 'bundled'")
    return Set(rows.compactMap { row -> Int64? in
      let id: Int64 = row["id"]
      let instructions: String = row["instructions"]
      return CookingGuideSteps(instructions: instructions).attribution == nil ? nil : id
    })
  }

  /// One readable name per ingredient ID. Legacy lines carry the `ingredients.name` key
  /// ("green_onion"); the catalog vocabulary names the same app ingredient through its
  /// `legacy_id` ("Green onion"), and catalog lines already carry vocabulary names. Keys the
  /// vocabulary doesn't cover are spelled out by `readableKey`.
  private static func readableNames(for recipes: [PlanCandidate], _ db: Database) throws
    -> [Int64: String]
  {
    var names: [Int64: String] = [:]
    let vocabulary = try Row.fetchAll(
      db,
      sql: """
        SELECT legacy_id, display_name FROM recipes_catalog_ingredients
        WHERE legacy_id IS NOT NULL ORDER BY key
        """)
    for row in vocabulary {
      let id: Int64 = row["legacy_id"]
      let name: String = row["display_name"]
      if names[id] == nil { names[id] = name }
    }
    // Catalog recipes have negative IDs; their lines carry vocabulary names.
    for line in recipes.filter({ $0.databaseID < 0 }).flatMap(\.lines)
    where names[line.ingredientID] == nil {
      names[line.ingredientID] = line.name
    }
    for line in recipes.filter({ $0.databaseID > 0 }).flatMap(\.lines)
    where names[line.ingredientID] == nil {
      names[line.ingredientID] = readableKey(line.name)
    }
    return names
  }

  /// "red_pepper_flakes" → "Red pepper flakes", matching the vocabulary's sentence case.
  /// A name that already has capitals is a display name and is only de-underscored.
  static func readableKey(_ key: String) -> String {
    let spaced = key.replacingOccurrences(of: "_", with: " ")
    guard spaced == spaced.lowercased(), let first = spaced.first else { return spaced }
    return first.uppercased() + spaced.dropFirst()
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
