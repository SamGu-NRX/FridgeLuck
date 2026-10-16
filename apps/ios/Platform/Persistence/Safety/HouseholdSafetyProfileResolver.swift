import FLFeatureLogic
import Foundation
import GRDB

/// Derives the household safety screen's inputs from the stored profile and the
/// shipped bundle's vocabulary, and screens whole recipes.
///
/// The allergen groups are re-derived from the stored ingredient ids at query
/// time with `AllergenSupport.group(for:)` — keyword matching over the CURRENT
/// ingredient table — so rows added after onboarding (later FDC vocabulary
/// additions) are covered without any profile rewrite.
enum HouseholdSafetyProfileResolver {
  /// Builds the household side of the screen from the stored health profile.
  ///
  /// - Parameters:
  ///   - allergenIds: the persisted allergen ingredient ids
  ///     (`health_profile.allergen_ingredient_ids`).
  ///   - dietID: the profile's selected diet id (`selectedDietID`), or nil.
  static func householdProfile(
    allergenIds: Set<Int64>, dietID: String?, in db: Database
  ) throws -> HouseholdSafetyProfile {
    var groups = Set<HouseholdAllergenGroup>()
    if !allergenIds.isEmpty {
      let placeholders = allergenIds.map { _ in "?" }.joined(separator: ",")
      let rows = try Ingredient.fetchAll(
        db,
        sql: "SELECT * FROM ingredients WHERE id IN (\(placeholders))",
        arguments: StatementArguments(allergenIds.sorted().map { $0 as Int64 }))
      for ingredient in rows {
        guard let group = AllergenSupport.group(for: ingredient) else { continue }
        if let screened = HouseholdAllergenGroup(rawValue: group.id) {
          groups.insert(screened)
        }
      }
    }
    return HouseholdSafetyProfile(allergenGroups: groups, diet: HouseholdDiet(rawValue: dietID ?? ""))
  }

  /// The whole vocabulary's classes, keyed by canonical key. A missing key (or
  /// an empty classes list) screens as unknown — fail closed.
  static func classesByKey(in db: Database) throws -> [String: [String]] {
    let rows = try Row.fetchAll(db, sql: "SELECT key, classes FROM recipes_catalog_ingredients")
    var byKey: [String: [String]] = [:]
    byKey.reserveCapacity(rows.count)
    for row in rows {
      let key: String = row["key"]
      let raw: String = row["classes"]
      if let data = raw.data(using: .utf8),
        let classes = try? JSONDecoder().decode([String].self, from: data)
      {
        byKey[key] = classes
      } else {
        byKey[key] = []
      }
    }
    return byKey
  }

  /// One recipe line's screen entry for a canonical key: the bundle classes, or
  /// unknown (empty) when the key is outside the vocabulary.
  static func lineSafety(key: String, classesByKey: [String: [String]]) -> RecipeLineSafety {
    RecipeLineSafety(classes: Set(classesByKey[key] ?? []))
  }

  /// Screens one catalog recipe's lines for a household. `keys` are the
  /// recipe's line keys in bundle order; `perServingCarbsGrams` rides along for
  /// the keto constant.
  static func screenCatalogRecipe(
    household: HouseholdSafetyProfile, lineKeys: [String], classesByKey: [String: [String]],
    perServingCarbsGrams: Double? = nil
  ) -> HouseholdSafetyVerdict {
    let lines = lineKeys.map { lineSafety(key: $0, classesByKey: classesByKey) }
    return HouseholdSafetyGate.screen(
      household: household, lines: lines, perServingCarbsGrams: perServingCarbsGrams)
  }

  /// Whether a household may be offered one catalog recipe. Recommendations
  /// (`RecipeRepository.catalogMatches`) and the weekly plan
  /// (`PlanDataAdapter.loadCatalogCandidates`) both admit through this, so one
  /// surface cannot offer a recipe the other refuses. The recipe is refused when:
  /// - the composition screen blocks it: an allergen group, a diet class, or, for
  ///   a household that restricts anything, a line with unknown composition;
  /// - any line's key bridges to an explicitly excluded app ingredient (the stored
  ///   allergen ids plus the diet's excluded ids). Every bridge row counts, not only
  ///   the one id a surface picks to stand for the line: the bridge can map one key
  ///   to several ids, and checking only the smallest let a recipe through whose
  ///   line was the household's flagged ingredient under its second id;
  /// - the selected diet's claim is not proven true. A null or undecodable claim is
  ///   unknown and refuses; keto always refuses because no claim expresses low-carb.
  static func admitsCatalogRecipe(
    household: HouseholdSafetyProfile, dietID: String?, lineKeys: [String],
    claimsJSON: String?, classesByKey: [String: [String]],
    bridgedIDsByKey: [String: Set<Int64>], excludedIDs: Set<Int64>
  ) -> Bool {
    if case .blocked = screenCatalogRecipe(
      household: household, lineKeys: lineKeys, classesByKey: classesByKey)
    {
      return false
    }
    if !excludedIDs.isEmpty,
      lineKeys.contains(where: { !(bridgedIDsByKey[$0] ?? []).isDisjoint(with: excludedIDs) })
    {
      return false
    }
    let claims = claimsJSON.flatMap {
      try? JSONDecoder().decode(RecipeCatalogClaims.self, from: Data($0.utf8))
    }
    switch dietID {
    case "vegetarian": return claims?.vegetarian == true
    case "vegan": return claims?.vegan == true
    case "keto": return false
    default: return true
    }
  }

  /// The class set for one app ingredient id, derived by keyword group: the
  /// group's screen class, or empty (unknown) when the ingredient matches no
  /// group and has no bundle vocabulary row.
  static func ingredientClasses(
    ingredientId: Int64, in db: Database, classesByKey: [String: [String]]
  ) throws -> Set<String> {
    // Bundle vocabulary first: the key's classes are the pinned contract.
    let keys = try String.fetchAll(
      db,
      sql: "SELECT ingredient_key FROM recipes_catalog_ingredient_bridge WHERE ingredient_id = ?",
      arguments: [ingredientId])
    if let key = keys.sorted().first, let classes = classesByKey[key], !classes.isEmpty {
      return Set(classes)
    }
    // Keyword-group derivation over the ingredient row itself.
    guard let ingredient = try Ingredient.fetchOne(
      db,
      sql: "SELECT * FROM ingredients WHERE id = ?",
      arguments: [ingredientId])
    else { return [] }
    if let group = AllergenSupport.group(for: ingredient),
      let mapped = HouseholdAllergenGroup(rawValue: group.id)
    {
      return [mapped.ingredientClass]
    }
    return []
  }
}
