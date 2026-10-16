import FLFeatureLogic
import Foundation
import GRDB

/// A recipe chosen to log a meal already eaten.
///
/// A catalog recipe carries `catalogRef` and logs against that exact revision, the way a
/// catalog meal cooked from Home does (`CookingCelebrationView` passes the cook packet's id and
/// revision to `MealLogService.logMeal`). The meal then reports the frozen per-revision
/// nutrition snapshot. A legacy recipe has no ref and logs through `resolveForLogging`.
struct MealLogPick: Sendable {
  let recipe: Recipe
  let macros: RecipeMacros
  let catalogRef: RecipeRef?
}

enum MealLogPickError: LocalizedError, Equatable {
  case unknownCatalogRecipe(String)
  case noNutritionSnapshot(catalogId: String, revision: Int)

  var errorDescription: String? {
    switch self {
    case .unknownCatalogRecipe(let catalogId):
      "Catalog recipe \(catalogId) isn't installed."
    case .noNutritionSnapshot(let catalogId, let revision):
      "Catalog recipe \(catalogId) has no nutrition stored for revision \(revision)."
    }
  }
}

/// The meal-log picker's recipe list. It used to read only the legacy `recipes` table, so of
/// the 762 catalog originals the app recommends none could be found by name (2026-10-16 walk
/// at alpha a32bfe3: "fried rice" and "peanut" found nothing).
extension RecipeRepository {
  /// Recipes whose title contains `query` (every recipe when it is empty), ordered by title:
  /// legacy rows the recipe audit's hide lists leave in place, and catalog originals.
  ///
  /// Like `searchRecipes`, this never hides a recipe the stored household's screen refuses,
  /// because the household is recording what it already ate; the entry carries the reason.
  func mealLogRecipes(matching query: String, limit: Int) throws -> [HouseholdScreenedRecipe] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let catalog = try screenedCatalogRecipes(matching: trimmed)
    let legacy =
      trimmed.isEmpty
      ? try fetchAllRecipes(limit: limit)
      : try searchRecipes(query: trimmed, limit: limit)
    // Logging a catalog meal lands on a `recipes` row with the catalog title (an
    // ingredientless row `resolvePersistedRecipeID` inserts). The catalog entry already
    // stands for that dish, and the row would log with no nutrition.
    let catalogTitles = Set(catalog.map { Self.titleKey($0.recipe.title) })
    let merged =
      legacy.filter { !catalogTitles.contains(Self.titleKey($0.recipe.title)) } + catalog
    return Array(
      merged.sorted {
        $0.recipe.title.localizedStandardCompare($1.recipe.title) == .orderedAscending
      }
      .prefix(limit))
  }

  /// The pick for a catalog recipe chosen in the picker, at the revision the picker listed,
  /// with that revision's frozen per-serving nutrition: the snapshot the logged meal reports.
  func catalogMealLogPick(_ ref: RecipeRef) throws -> MealLogPick {
    try db.read { db in
      guard
        let header = try Row.fetchOne(
          db,
          sql: """
            SELECT title, minutes, servings FROM recipes_catalog
            WHERE catalog_id = ? AND rights_status = 'original'
            """,
          arguments: [ref.id])
      else { throw MealLogPickError.unknownCatalogRecipe(ref.id) }
      guard
        let json = try String.fetchOne(
          db,
          sql:
            "SELECT nutrition FROM recipes_catalog_nutrition WHERE catalog_id = ? AND revision = ?",
          arguments: [ref.id, ref.revision])
      else { throw MealLogPickError.noNutritionSnapshot(catalogId: ref.id, revision: ref.revision) }
      let nutrition = try JSONDecoder().decode(RecipeCatalogNutrition.self, from: Data(json.utf8))
      return MealLogPick(
        recipe: Self.catalogLoggingRecipe(
          title: header["title"], minutes: header["minutes"], servings: header["servings"]),
        macros: Self.catalogMacros(from: nutrition),
        catalogRef: ref)
    }
  }

  /// The household's verdict on a catalog recipe, with a reason the picker can show.
  ///
  /// Admission is `HouseholdSafetyBoundary.admitsCatalogRecipe`, the rule recommendations and
  /// the weekly plan apply, and it alone decides allowed or refused. The steps below only name
  /// why a refused recipe is refused, checked in the rule's order: line composition, a flagged
  /// ingredient, the diet claim. A refusal none of them explains reads as unknown composition.
  static func catalogMealLogVerdict(
    boundary: HouseholdSafetyBoundary, lineKeys: [String], claimsJSON: String?
  ) -> HouseholdSafetyVerdict {
    guard !boundary.admitsCatalogRecipe(lineKeys: lineKeys, claimsJSON: claimsJSON) else {
      return .allowed
    }
    if case .blocked(let block) = HouseholdSafetyProfileResolver.screenCatalogRecipe(
      household: boundary.household, lineKeys: lineKeys, classesByKey: boundary.classesByKey)
    {
      return .blocked(block)
    }
    if let flagged = lineKeys.lazy.compactMap({
      (boundary.bridgedIDsByKey[$0] ?? []).intersection(boundary.excludedIDs).min()
    }).first {
      return .blocked(.excludedIngredient(flagged))
    }
    if let diet = boundary.household.diet, [HouseholdDiet.vegetarian, .vegan, .keto].contains(diet) {
      return .blocked(.diet(diet))
    }
    return .blocked(.unknownComposition)
  }

  /// Catalog originals whose title contains `query`, screened for the stored household.
  /// Quarantined recipes never reach this: the bundle compiler leaves them out of
  /// recipes-v2.json, and legacy rows hydrated into `recipes_catalog` are not `original`.
  private func screenedCatalogRecipes(matching query: String) throws -> [HouseholdScreenedRecipe] {
    try db.read { db in
      let headers = try Row.fetchAll(
        db,
        sql: """
          SELECT catalog_id, revision, title, minutes, servings, claims
          FROM recipes_catalog
          WHERE rights_status = 'original'
          """
      ).filter { row in
        query.isEmpty
          || (row["title"] as String).range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
      guard !headers.isEmpty else { return [] }

      var keysByRecipe: [String: [String]] = [:]
      for row in try Row.fetchAll(
        db,
        sql: "SELECT catalog_id, ingredient_key FROM recipes_catalog_lines ORDER BY position")
      {
        keysByRecipe[row["catalog_id"], default: []].append(row["ingredient_key"])
      }

      let boundary = try HouseholdSafetyBoundary.loadStored(in: db)
      return try headers.map { header in
        let catalogId: String = header["catalog_id"]
        let verdict = Self.catalogMealLogVerdict(
          boundary: boundary, lineKeys: keysByRecipe[catalogId] ?? [], claimsJSON: header["claims"])
        return HouseholdScreenedRecipe(
          recipe: Self.catalogLoggingRecipe(
            title: header["title"], minutes: header["minutes"], servings: header["servings"]),
          verdict: verdict,
          warning: try HouseholdSafetyBoundary.warning(for: verdict, in: db),
          catalogRef: .catalog(id: catalogId, revision: header["revision"]))
      }
    }
  }

  /// The id-less recipe a catalog meal logs as, the same shape catalog recommendations carry.
  private static func catalogLoggingRecipe(title: String, minutes: Int?, servings: Int?) -> Recipe {
    Recipe(
      id: nil,
      title: title,
      timeMinutes: minutes ?? 30,
      servings: servings ?? 2,
      instructions: "",
      tags: 0,
      source: .bundled,
      createdAt: nil
    )
  }

  private static func titleKey(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
