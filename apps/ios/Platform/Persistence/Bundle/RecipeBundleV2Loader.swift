import FLFeatureLogic
import Foundation
import GRDB

/// Hydrates the recipe catalog tables from the bundled recipe bundle.
///
/// The bundle source is `Resources/RecipeCatalog/recipes-v2.json` when the app bundle ships
/// it, else the legacy `data.json` (hydrated into catalog rows keyed `rcp-NNNNNN` by their
/// legacy integer ids, so a later bundle revision supersedes them in place). Applies are
/// idempotent: same revision is a no-op, a higher revision replaces lines and steps,
/// user-edited rows are never touched, and per-revision nutrition history is never rewritten.
enum RecipeBundleV2Loader {
  private enum StateKey {
    static let marker = "recipes_catalog_v2_marker"
  }

  /// Launch entry point. Reads recipes-v2.json when present, legacy data.json otherwise.
  static func ensureCatalogHydrated(into appDB: AppDatabase) async throws {
    if let v2URL = bundleV2URL(in: .main) {
      try await apply(
        data: try Data(contentsOf: v2URL), into: appDB.dbQueue, marker: marker(for: v2URL))
      return
    }
    guard let legacyURL = Bundle.main.url(forResource: "data", withExtension: "json") else {
      return
    }
    try await applyLegacy(
      data: try Data(contentsOf: legacyURL), into: appDB.dbQueue, marker: marker(for: legacyURL))
  }

  /// The shipped v2 bundle, under Resources/RecipeCatalog/ or at the resources root.
  static func bundleV2URL(in bundle: Bundle) -> URL? {
    bundle.url(forResource: "recipes-v2", withExtension: "json", subdirectory: "RecipeCatalog")
      ?? bundle.url(forResource: "recipes-v2", withExtension: "json")
  }

  private static func marker(for url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let fileSize = values?.fileSize ?? 0
    let modifiedAt = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    return "size=\(fileSize);mtime=\(modifiedAt)"
  }

  // MARK: - Bundle v2

  /// Applies a bundle v2 payload. Throws with the recipe id on any malformed recipe.
  static func apply(data: Data, into dbQueue: DatabaseQueue, marker: String) async throws {
    let bundle = try RecipeBundleV2.decode(from: data)
    try await dbQueue.write { db in
      try apply(bundle: bundle, marker: marker, db: db)
      try setMarker(db, value: marker)
    }
  }

  /// Transactional apply, exposed for tests. Assumes `db` is in a write transaction.
  static func apply(bundle: RecipeBundleV2, marker: String, db: Database) throws {
    for ingredient in bundle.ingredients {
      try upsertIngredient(ingredient, db: db)
    }
    for recipe in bundle.recipes {
      try upsertV2Recipe(recipe, marker: marker, db: db)
    }
    // Same transaction as the vocabulary upsert: the bridge is rebuilt from exactly the
    // rows this apply wrote, so key resolution can never drift from the vocabulary.
    try RecipeCatalogIngredientBridge.rebuild(db: db)
  }

  private static func upsertIngredient(_ ingredient: RecipeCatalogIngredient, db: Database)
    throws
  {
    // COALESCE keeps previously established per-100 g evidence when an incoming bundle
    // entry carries none, so vocabulary hydration never deletes evidence.
    try db.execute(
      sql: """
        INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category, per_100g, aliases)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            fdc_id = excluded.fdc_id,
            legacy_id = excluded.legacy_id,
            display_name = excluded.display_name,
            category = excluded.category,
            per_100g = COALESCE(excluded.per_100g, recipes_catalog_ingredients.per_100g),
            aliases = excluded.aliases
        """,
      arguments: [
        ingredient.key,
        ingredient.fdcId,
        ingredient.legacyId,
        ingredient.displayName,
        ingredient.category,
        ingredient.per100g.map(Self.encodeJSON),
        Self.encodeJSON(ingredient.aliases),
      ]
    )
  }

  private static func upsertV2Recipe(_ recipe: RecipeBundleRecipe, marker: String, db: Database)
    throws
  {
    let existing = try Row.fetchOne(
      db,
      sql:
        "SELECT revision, is_user_edited, rights_status, legacy_recipe_id FROM recipes_catalog WHERE catalog_id = ?",
      arguments: [recipe.catalogId]
    )

    if let existing {
      let isUserEdited: Bool = existing["is_user_edited"]
      let storedRevision: Int = existing["revision"]
      // User-edited rows survive every re-apply; same-or-older revisions are no-ops,
      // which is what makes repeated launches idempotent.
      if isUserEdited { return }
      // A quarantined legacy fallback row is a stand-in until real structured content
      // lands, so a bundle recipe supersedes it even at the same revision. Its legacy
      // link survives only when this recipe is genuinely the successor (same title,
      // checked below) — preserving it blindly would misattribute cooking history.
      let storedRights: String = existing["rights_status"]
      let isQuarantinedFallback =
        storedRights == RecipeCatalogRightsStatus.quarantined.rawValue
        && existing["legacy_recipe_id"] != nil
      if !isQuarantinedFallback && storedRevision >= recipe.revision { return }
      try writeRecipe(
        recipe,
        legacyRecipeId: linkedLegacyRecipeID(for: recipe, in: db),
        marker: marker,
        replace: true,
        db: db
      )
    } else {
      try writeRecipe(
        recipe,
        legacyRecipeId: linkedLegacyRecipeID(for: recipe, in: db),
        marker: marker,
        replace: false,
        db: db
      )
    }
  }

  /// A bundle recipe succeeds a legacy row when its catalog_id suffix names a bundled
  /// legacy recipe with the same title (spec: migrated rows keep rcp-000001..rcp-000166
  /// by their legacy integer id). Anything else stays unlinked — a false link would
  /// misattribute cooking history.
  private static func linkedLegacyRecipeID(for recipe: RecipeBundleRecipe, in db: Database)
    throws -> Int64?
  {
    let suffix = recipe.catalogId.dropFirst("rcp-".count)
    guard let legacyID = Int64(suffix), legacyID >= 1, legacyID <= 166 else { return nil }
    let titleKey = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return try Int64.fetchOne(
      db,
      sql: """
        SELECT id FROM recipes
        WHERE id = ? AND source = 'bundled' AND LOWER(TRIM(title)) = ?
        LIMIT 1
        """,
      arguments: [legacyID, titleKey]
    )
  }

  private static func writeRecipe(
    _ recipe: RecipeBundleRecipe,
    legacyRecipeId: Int64?,
    marker: String,
    replace: Bool,
    db: Database
  ) throws {
    if replace {
      try db.execute(
        sql: """
          UPDATE recipes_catalog SET
              revision = ?, title = ?, cuisine = ?, meal_slots = ?, collections = ?,
              minutes = ?, servings = ?, equipment = ?, claims = ?, nutrition = ?,
              rights_status = ?, rights_evidence = ?, keywords = ?,
              legacy_recipe_id = ?, source_bundle = ?, updated_at = CURRENT_TIMESTAMP
          WHERE catalog_id = ?
          """,
        arguments: [
          recipe.revision, recipe.title, recipe.cuisine.rawValue,
          Self.encodeJSON(recipe.mealSlots), Self.encodeJSON(recipe.collections),
          recipe.minutes, recipe.servings, Self.encodeJSON(recipe.equipment),
          Self.encodeJSON(recipe.claims), Self.encodeJSON(recipe.nutrition),
          recipe.rights.status.rawValue, recipe.rights.evidence,
          Self.encodeJSON(recipe.keywords),
          legacyRecipeId, marker, recipe.catalogId,
        ]
      )
    } else {
      try db.execute(
        sql: """
          INSERT INTO recipes_catalog
              (catalog_id, revision, title, cuisine, meal_slots, collections, minutes,
               servings, equipment, claims, nutrition, rights_status, rights_evidence,
               keywords, legacy_recipe_id, is_user_edited, source_bundle, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, CURRENT_TIMESTAMP)
          """,
        arguments: [
          recipe.catalogId, recipe.revision, recipe.title, recipe.cuisine.rawValue,
          Self.encodeJSON(recipe.mealSlots), Self.encodeJSON(recipe.collections),
          recipe.minutes, recipe.servings, Self.encodeJSON(recipe.equipment),
          Self.encodeJSON(recipe.claims), Self.encodeJSON(recipe.nutrition),
          recipe.rights.status.rawValue, recipe.rights.evidence,
          Self.encodeJSON(recipe.keywords),
          legacyRecipeId, marker,
        ]
      )
    }

    try db.execute(
      sql: "DELETE FROM recipes_catalog_lines WHERE catalog_id = ?",
      arguments: [recipe.catalogId])
    try db.execute(
      sql: "DELETE FROM recipes_catalog_steps WHERE catalog_id = ?",
      arguments: [recipe.catalogId])

    for (position, line) in recipe.lines.enumerated() {
      let quantity = Self.quantityColumns(line.quantity)
      try db.execute(
        sql: """
          INSERT INTO recipes_catalog_lines
              (catalog_id, position, ingredient_key, quantity_kind, quantity_grams,
               quantity_amount, quantity_unit, quantity_note, is_required,
               assumed_staple, note)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          recipe.catalogId, position, line.key, quantity.kind, quantity.grams,
          quantity.amount, quantity.unit, quantity.note, line.required,
          line.assumedStaple, line.note,
        ]
      )
    }

    for (position, step) in recipe.steps.enumerated() {
      let thermometer = step.thermometer
      try db.execute(
        sql: """
          INSERT INTO recipes_catalog_steps
              (catalog_id, position, text, uses, timer_seconds,
               thermometer_endpoint_c, thermometer_food, thermometer_source)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          recipe.catalogId, position, step.text, Self.encodeJSON(step.uses),
          step.timerSeconds,
          thermometer?.endpointC, thermometer?.food, thermometer?.source,
        ]
      )
    }

    // Historical nutrition: written once per revision, never updated.
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO recipes_catalog_nutrition (catalog_id, revision, nutrition)
        VALUES (?, ?, ?)
        """,
      arguments: [recipe.catalogId, recipe.revision, Self.encodeJSON(recipe.nutrition)]
    )
  }

  private static func quantityColumns(_ quantity: RecipeCatalogQuantity) -> (
    kind: String, grams: Double?, amount: Double?, unit: String?, note: String?
  ) {
    switch quantity {
    case .grams(let grams):
      return ("grams", grams, nil, nil, nil)
    case .count(let amount, let unit, let grams):
      return ("count", grams, amount, unit, nil)
    case .household(let amount, let unit, let grams):
      return ("household", grams, amount, unit, nil)
    case .unknown(let note):
      return ("unknown", nil, nil, nil, note)
    }
  }

  // MARK: - Legacy fallback

  /// Applies the legacy data.json into catalog rows keyed rcp-NNNNNN by the legacy integer
  /// id, revision 1, with the legacy link set. A shipped bundle v2 later supersedes these
  /// rows by revision bump; re-applying legacy data after that is a no-op.
  static func applyLegacy(data: Data, into dbQueue: DatabaseQueue, marker: String) async throws {
    let bundled = try JSONDecoder().decode(BundledData.self, from: data)
    try await dbQueue.write { db in
      try applyLegacy(bundled: bundled, marker: marker, db: db)
      try setMarker(db, value: marker)
    }
  }

  /// Transactional legacy apply, exposed for tests. Assumes `db` is in a write transaction.
  static func applyLegacy(bundled: BundledData, marker: String, db: Database) throws {
    for (idString, raw) in bundled.ingredients {
      guard let legacyID = Int64(idString) else { continue }
      try upsertLegacyIngredient(legacyID: legacyID, raw: raw, db: db)
    }

    for raw in bundled.recipes {
      let catalogId = String(format: "rcp-%06d", raw.id)
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM recipes_catalog WHERE catalog_id = ?)",
          arguments: [catalogId]
        ) ?? false
      guard !exists else { continue }

      try writeLegacyRecipe(raw: raw, catalogId: catalogId, marker: marker, db: db)
    }

    // Same transaction as the vocabulary upsert (legacy installs resolve through
    // legacy_id; the shipped bundle path resolves through fdc_id).
    try RecipeCatalogIngredientBridge.rebuild(db: db)
  }

  private static func upsertLegacyIngredient(legacyID: Int64, raw: IngredientArray, db: Database)
    throws
  {
    // data.json names are already canonical slugs ("olive_oil"); sodium is grams in the
    // legacy file, milligrams in the catalog.
    let per100g = RecipeCatalogPer100g(
      kcal: raw.calories, proteinG: raw.protein, carbsG: raw.carbs, fatG: raw.fat,
      fiberG: raw.fiber, sugarG: raw.sugar, sodiumMg: raw.sodium * 1000
    )
    try db.execute(
      sql: """
        INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category, per_100g, aliases)
        VALUES (?, NULL, ?, ?, 'legacy', ?, '[]')
        ON CONFLICT(key) DO UPDATE SET
            legacy_id = COALESCE(recipes_catalog_ingredients.legacy_id, excluded.legacy_id),
            per_100g = COALESCE(excluded.per_100g, recipes_catalog_ingredients.per_100g)
        """,
      arguments: [
        raw.name, legacyID,
        raw.name.replacingOccurrences(of: "_", with: " "),
        Self.encodeJSON(per100g),
      ]
    )
  }

  private static func writeLegacyRecipe(
    raw: RecipeArray, catalogId: String, marker: String, db: Database
  ) throws {
    let tags = RecipeTags(rawValue: raw.tagBitmask)
    let cuisine: RecipeCatalogCuisine =
      tags.contains(.asian)
      ? .asian
      : tags.contains(.mediterranean)
        ? .mediterranean
        : tags.contains(.mexican) ? .mexican : .american
    let mealSlots: [RecipeCatalogMealSlot] =
      tags.contains(.breakfast) ? [.breakfast] : [.lunch, .dinner]
    var collections: [RecipeCatalogCollection] = []
    if tags.contains(.quick) { collections.append(.quick) }
    if tags.contains(.budget) { collections.append(.budget) }
    if tags.contains(.comfort) { collections.append(.comfort) }
    if tags.contains(.onePot) { collections.append(.onePot) }

    // Unknown rights means quarantine: legacy rows predate the rights audit and carry no
    // licence evidence, so they are display-only and excluded from sharing.
    let rights = RecipeCatalogRights(
      status: .quarantined,
      evidence: "legacy data.json row; provenance not established (rights audit, PR #43)")

    try db.execute(
      sql: """
        INSERT INTO recipes_catalog
            (catalog_id, revision, title, cuisine, meal_slots, collections, minutes,
             servings, equipment, claims, nutrition, rights_status, rights_evidence,
             keywords, legacy_recipe_id, is_user_edited, source_bundle, updated_at)
        VALUES (?, 1, ?, ?, ?, ?, ?, ?, '[]', ?, NULL, ?, ?, ?, ?, 0, ?, CURRENT_TIMESTAMP)
        """,
      arguments: [
        catalogId, raw.title, cuisine.rawValue, Self.encodeJSON(mealSlots),
        Self.encodeJSON(collections), raw.timeMinutes, raw.servings,
        Self.encodeJSON(
          RecipeCatalogClaims(vegetarian: nil, vegan: nil, glutenFree: nil, dairyFree: nil)),
        rights.status.rawValue, rights.evidence,
        Self.encodeJSON([raw.title.lowercased()]),
        Int64(raw.id), marker,
      ]
    )

    var position = 0
    for (ingredientId, grams) in raw.requiredIngredients {
      try writeLegacyLine(
        raw: raw, ingredientId: ingredientId, grams: grams, required: true,
        position: position, catalogId: catalogId, db: db)
      position += 1
    }
    for (ingredientId, grams) in raw.optionalIngredients {
      try writeLegacyLine(
        raw: raw, ingredientId: ingredientId, grams: grams, required: false,
        position: position, catalogId: catalogId, db: db)
      position += 1
    }
    // Steps stay empty: legacy rows render through the existing instructions path until a
    // bundle v2 revision supplies structured steps.
  }

  private static func writeLegacyLine(
    raw: RecipeArray, ingredientId: Int, grams: Double, required: Bool,
    position: Int, catalogId: String, db: Database
  ) throws {
    // The vocabulary row must exist first (foreign key). Legacy data is internally
    // consistent; a missing entry would mean a corrupt bundle, so the line is skipped
    // rather than failing the whole hydration.
    guard let name = try bundledIngredientName(ingredientId: ingredientId, in: raw, db: db) else {
      return
    }
    try db.execute(
      sql: """
        INSERT INTO recipes_catalog_lines
            (catalog_id, position, ingredient_key, quantity_kind, quantity_grams,
             quantity_amount, quantity_unit, quantity_note, is_required,
             assumed_staple, note)
        VALUES (?, ?, ?, 'grams', ?, NULL, NULL, NULL, ?, 0, NULL)
        """,
      arguments: [catalogId, position, name, grams, required]
    )
  }

  private static func bundledIngredientName(
    ingredientId: Int, in raw: RecipeArray, db: Database
  ) throws -> String? {
    try String.fetchOne(
      db,
      sql: "SELECT key FROM recipes_catalog_ingredients WHERE legacy_id = ? LIMIT 1",
      arguments: [ingredientId]
    )
  }

  // MARK: - Helpers

  private static func setMarker(_ db: Database, value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO bundled_recipe_state (key, value, updated_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = CURRENT_TIMESTAMP
        """,
      arguments: [StateKey.marker, value]
    )
  }

  private static let jsonEncoder = JSONEncoder()

  static func encodeJSON<T: Encodable>(_ value: T) -> String {
    let data = (try? jsonEncoder.encode(value)) ?? Data("null".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}
