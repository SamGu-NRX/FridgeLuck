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

  /// Whether a household may be offered one catalog recipe. Every catalog surface admits
  /// through this, most of them by way of `HouseholdSafetyBoundary.admitsCatalogRecipe`,
  /// so one surface cannot offer a recipe another refuses. The recipe is refused when:
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
}
