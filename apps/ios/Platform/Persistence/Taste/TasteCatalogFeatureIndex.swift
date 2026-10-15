import Foundation
import GRDB

import FLFeatureLogic

/// The bundle-v2 feature index shared by the live ranker and the taste
/// profile: per-recipe feature keys (`TasteFeatureExtractorV2` over the
/// shipped bundle), feature-key display names from the v2 vocabulary, and the
/// identity bridges from the catalog tables — the legacy recipe ids that
/// catalog rows supersede, and legacy ingredient ids mapped to their canonical
/// vocabulary keys.
///
/// Both event vocabularies resolve here. Cook events log the legacy numeric
/// recipe id as a string (the legacy `recipes.id`), while catalog-cook events
/// log the bundle's catalog id; the ranker keys and the profile evidence land
/// on the same canonical feature keys either way. The shipped v2 bundle links
/// its rows to the legacy pool through `recipes_catalog.legacy_recipe_id`
/// (`RecipeBundleV2Loader.linkedLegacyRecipeID`), which is the bridge this
/// index mirrors from the database.
struct TasteCatalogFeatureIndex: Sendable {
  /// Catalog id (and aliased legacy-successor ids) -> sorted feature keys.
  let featureKeysByRecipe: [String: [String]]
  /// Feature key -> display name (vocabulary display names lowercased for
  /// `ingredient:` keys, humanized suffixes otherwise).
  let nameOf: [String: String]
  /// Legacy numeric recipe id (string form) -> the catalog id superseding it.
  let successorCatalogIdByLegacyRecipe: [String: String]
  /// Legacy numeric ingredient id (string form) -> canonical vocabulary key.
  let canonicalKeyByLegacyIngredient: [String: String]

  static let empty = TasteCatalogFeatureIndex(
    featureKeysByRecipe: [:], nameOf: [:],
    successorCatalogIdByLegacyRecipe: [:], canonicalKeyByLegacyIngredient: [:])

  /// Builds the bundle half from the app's shipped recipes-v2.json
  /// (RecipeCatalog/). Empty when the bundle is missing or undecodable — the
  /// consumers degrade to legacy behavior, never crash.
  static func bundled() -> TasteCatalogFeatureIndex {
    guard
      let url = RecipeBundleV2Loader.bundleV2URL(in: .main),
      let data = try? Data(contentsOf: url),
      let bundle = try? RecipeBundleV2.decode(from: data)
    else { return .empty }
    let (featureKeysByRecipe, nameOf) = TasteFeatureExtractorV2.extractCatalog(bundle: bundle)
    return TasteCatalogFeatureIndex(
      featureKeysByRecipe: featureKeysByRecipe, nameOf: nameOf,
      successorCatalogIdByLegacyRecipe: [:], canonicalKeyByLegacyIngredient: [:])
  }

  /// Adds the catalog-table bridges from the database: legacy recipe successor
  /// links (`recipes_catalog.legacy_recipe_id`) and legacy ingredient id ->
  /// canonical key (`recipes_catalog_ingredients.legacy_id`). On any database
  /// failure the un-bridged index is returned — the ranker and profile still
  /// work for catalog-id events.
  func withDatabaseBridges(
    dbQueue: DatabaseQueue
  ) -> TasteCatalogFeatureIndex {
    guard !featureKeysByRecipe.isEmpty || !nameOf.isEmpty else { return self }
    do {
      return try dbQueue.read { db in
        var successors: [String: String] = self.successorCatalogIdByLegacyRecipe
        let recipeRows = try Row.fetchAll(
          db, sql: "SELECT catalog_id, legacy_recipe_id FROM recipes_catalog WHERE legacy_recipe_id IS NOT NULL")
        for row in recipeRows {
          let legacyId: Int64 = row["legacy_recipe_id"]
          successors[String(legacyId)] = row["catalog_id"]
        }
        var canonicalByLegacy: [String: String] = self.canonicalKeyByLegacyIngredient
        let ingredientRows = try Row.fetchAll(
          db, sql: "SELECT key, legacy_id FROM recipes_catalog_ingredients WHERE legacy_id IS NOT NULL")
        for row in ingredientRows {
          let legacyId: Int64 = row["legacy_id"]
          canonicalByLegacy[String(legacyId)] = row["key"]
        }
        return TasteCatalogFeatureIndex(
          featureKeysByRecipe: self.featureKeysByRecipe, nameOf: self.nameOf,
          successorCatalogIdByLegacyRecipe: successors,
          canonicalKeyByLegacyIngredient: canonicalByLegacy)
      }
    } catch {
      return self
    }
  }

  // MARK: - Resolution

  /// Feature-key map covering both event vocabularies: the bundle's catalog ids
  /// plus each legacy successor link aliased to its superseding catalog row's
  /// features. The ranker consumes this — cook events log the legacy numeric id
  /// while the bundle keys features on catalog ids.
  var aliasedFeatureKeysByRecipe: [String: [String]] {
    var aliased = featureKeysByRecipe
    for (legacyId, catalogId) in successorCatalogIdByLegacyRecipe
    where aliased[legacyId] == nil {
      if let features = featureKeysByRecipe[catalogId] {
        aliased[legacyId] = features
      }
    }
    return aliased
  }


  /// The catalog id whose features cover `recipeId`: the id itself when the
  /// bundle carries it, else the superseding catalog row's id.
  func catalogId(forRecipeId recipeId: String) -> String? {
    if featureKeysByRecipe[recipeId] != nil { return recipeId }
    return successorCatalogIdByLegacyRecipe[recipeId]
  }

  /// Sorted feature keys for a recipe id in either event vocabulary; empty
  /// when neither the bundle nor a successor link covers it.
  func featureKeys(forRecipeId recipeId: String) -> [String] {
    guard let catalogId = catalogId(forRecipeId: recipeId) else { return [] }
    return featureKeysByRecipe[catalogId] ?? []
  }

  /// Canonical ingredient keys of a recipe's `ingredient:` features — what the
  /// profile's evidence aggregates key on for catalog cooks.
  func ingredientKeys(forRecipeId recipeId: String) -> [String] {
    featureKeys(forRecipeId: recipeId).compactMap { key in
      key.hasPrefix("ingredient:") ? String(key.dropFirst("ingredient:".count)) : nil
    }
  }

  /// Canonical vocabulary key for a legacy numeric ingredient id, when the
  /// vocabulary bridges one.
  func canonicalKey(forLegacyIngredientId id: Int64) -> String? {
    canonicalKeyByLegacyIngredient[String(id)]
  }

  /// Display name for a feature key. Canonical keys resolve through the bundle
  /// vocabulary; legacy numeric ids fall through to the caller's table names.
  func name(ofFeatureKey key: String) -> String? {
    nameOf[key]
  }
}
