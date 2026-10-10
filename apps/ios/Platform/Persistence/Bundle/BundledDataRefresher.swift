import Foundation
import GRDB

/// Counts from one refresh pass. Adoption happens at most once per install; the
/// update/insert counts repeat every launch (and are mostly zero, because bundles
/// rarely change between releases).
struct BundledDataRefreshOutcome: Equatable {
  var ingredientsAdopted = 0
  var recipesAdopted = 0
  var ingredientsUpdated = 0
  var recipesUpdated = 0
  var ingredientsInserted = 0
  var recipesInserted = 0
}

enum BundledDataRefreshError: Error, CustomStringConvertible {
  /// The current bundle payload failed validation. Nothing was written.
  case invalidPayload(problems: [String])

  /// After applying the payload, some entry still did not end up owned by exactly
  /// one row carrying the payload's content, without a diagnostic explaining why.
  /// The whole transaction rolls back — never ship a half-applied bundle.
  case postConditionFailed(String)

  var description: String {
    switch self {
    case .invalidPayload(let problems):
      return "current bundle payload is invalid: \(problems.joined(separator: "; "))"
    case .postConditionFailed(let reason):
      return "bundle refresh postcondition failed: \(reason)"
    }
  }
}

/// The safe bundled-data refresh.
///
/// Bundled data (recipes, data.json ingredients, the USDA catalog) ships inside the
/// app and gets written into the local database. Two histories collide here: users
/// keep installed row ids alive through inventory and cooking history, while bundle
/// entries are re-decoded from JSON with their own numeric ids on every launch.
/// This module is the bridge:
///
/// 1. Adoption (once per install): rows written by past hydration/catalog imports
///    are matched against pinned, hash-verified snapshots of the exact payloads
///    those releases shipped. Content that matches completely — including recipe
///    ingredient relationships — is adopted and stamped with its bundle entry's
///    ownership key. Anything ambiguous or modified stays unowned and gets a
///    diagnostic. A pin corpus that is missing or fails integrity verification
///    refuses the whole refresh upstream (LegacyBundlePins).
/// 2. Refresh (every launch): owned rows are updated in place to the current
///    payload when they still carry what the bundle last wrote, inserted when new,
///    and left alone with a diagnostic when the user or another system modified
///    them. Rows are never deleted. Every phase runs inside one write transaction
///    with a final postcondition, so a failure anywhere leaves the database
///    exactly as it was.
enum BundledDataRefresher {
  // MARK: - Inputs

  struct Pass: Sendable {
    /// The decoded current bundle payload (data.json).
    let current: BundledData
    /// SHA-256 hex over the raw current data.json bytes; recorded as a marker.
    let currentDataSha256: String
    /// The current catalog payload. The app has shipped exactly one catalog
    /// (pinned as v1); this is its verified export.
    let catalog: [LegacyCatalogIngredient]
    /// Verified pinned payloads for legacy adoption.
    let pins: [PinnedBundlePayload]
  }

  /// Test seams invoked inside the write transaction between phases, so tests can
  /// crash a pass at a known point and verify nothing was committed.
  struct InjectionPoints {
    var afterAdoption: (() throws -> Void)?
    var afterRowUpdates: (() throws -> Void)?
  }

  // MARK: - Entry points

  static func refresh(
    appDB: AppDatabase,
    pass: Pass,
    injections: InjectionPoints = InjectionPoints()
  ) async throws -> BundledDataRefreshOutcome {
    var outcome = BundledDataRefreshOutcome()
    try await appDB.dbQueue.write { db in
      outcome = try refreshInTransaction(db: db, pass: pass, injections: injections)
    }
    return outcome
  }

  /// Runs the whole pass inside the caller's transaction. Rolls back on any throw.
  static func refreshInTransaction(
    db: Database,
    pass: Pass,
    injections: InjectionPoints = InjectionPoints()
  ) throws -> BundledDataRefreshOutcome {
    var outcome = BundledDataRefreshOutcome()

    if let problems = Self.validate(pass.current) {
      throw BundledDataRefreshError.invalidPayload(problems: problems)
    }

    if try fetchStateValue(db, key: "ownership_ready") != "1" {
      try adoptLegacyRows(db: db, pass: pass, outcome: &outcome)
      try setStateValue(db, key: "ownership_ready", value: "1")
      try setStateValue(db, key: "adoption_completed_at", value: isoTimestamp())
      try injections.afterAdoption?()
    }

    try applyCurrentPayload(db: db, pass: pass, outcome: &outcome)
    try injections.afterRowUpdates?()

    try recordRemovals(db: db, pass: pass)
    try setStateValue(db, key: "refresh_bundle_hash", value: pass.currentDataSha256)
    try setStateValue(db, key: "refresh_completed_at", value: isoTimestamp())

    try verifyPostConditions(db: db, pass: pass)
    return outcome
  }
  // MARK: - Pass construction

  /// Builds the pass for the currently shipped bundle. The catalog payload rides
  /// with the pins: the app has shipped exactly one catalog (pinned as v1), whose
  /// verified export describes the same rows the bundled catalog SQLite contains.
  /// When the current data.json matches a pin exactly, that pin's catalog is used;
  /// otherwise the most recent pin's catalog is the best available description of
  /// the catalog this app build ships.
  static func loadCurrentPass(
    current: BundledData,
    currentDataSha256: String,
    pins: [PinnedBundlePayload]
  ) -> Pass {
    let catalog =
      pins.first { $0.dataSha256 == currentDataSha256 }?.catalog
      ?? pins.last?.catalog
      ?? []
    return Pass(
      current: current,
      currentDataSha256: currentDataSha256,
      catalog: catalog,
      pins: pins)
  }

  private static func validate(_ payload: BundledData) -> [String]? {
    do {
      try BundledDataValidator.validate(payload)
      return nil
    } catch let error as BundledDataValidationError {
      return error.problems
    } catch {
      return [String(describing: error)]
    }
  }

  // MARK: - Phase 1: adoption

  private struct PinIngredientCandidate {
    let ownershipKey: String
    let contentHash: String
  }

  private struct PinRecipeCandidate {
    let ownershipKey: String
    let contentHash: String
    /// Sorted "normalized ingredient name / required / grams" lines covering the
    /// recipe's required and optional relationships, built from the pin's own
    /// ingredients. Excludes display_quantity, which is derived text.
    let relationshipFingerprint: String
  }

  private static func adoptLegacyRows(
    db: Database, pass: Pass, outcome: inout BundledDataRefreshOutcome
  ) throws {
    // Index the pins by normalized name so matching never depends on the id drift
    // that motivated adoption in the first place.
    var dataJsonIngredientPins: [String: [PinIngredientCandidate]] = [:]
    var catalogIngredientPins: [String: [PinIngredientCandidate]] = [:]
    for pin in pass.pins {
      for (idString, raw) in pin.data.ingredients {
        guard let id = Int(idString) else { continue }
        dataJsonIngredientPins[BundledDataValidator.normalizedKey(raw.name) ?? "\u{0}", default: []]
          .append(
            PinIngredientCandidate(
              ownershipKey: BundleOwnership.ingredientKey(bundleIngredientId: id),
              contentHash: CanonicalHash.hash(
                fields: BundleRowProjection.dataJsonIngredientFields(raw))))
      }
      for raw in pin.catalog {
        catalogIngredientPins[BundledDataValidator.normalizedKey(raw.name) ?? "\u{0}", default: []]
          .append(
            PinIngredientCandidate(
              ownershipKey: BundleOwnership.usdaIngredientKey(fdcId: raw.fdcId),
              contentHash: CanonicalHash.hash(
                fields: BundleRowProjection.catalogIngredientFields(raw))))
      }
    }

    var recipePinIndex: [String: [PinRecipeCandidate]] = [:]
    for pin in pass.pins {
      for raw in pin.data.recipes {
        let candidate = PinRecipeCandidate(
          ownershipKey: BundleOwnership.recipeKey(bundleRecipeId: raw.id),
          contentHash: CanonicalHash.hash(fields: BundleRowProjection.recipeFields(raw)),
          relationshipFingerprint: pinRecipeFingerprint(
            required: raw.requiredIngredients, optional: raw.optionalIngredients,
            ingredients: pin.data.ingredients))
        recipePinIndex[BundledDataValidator.normalizedKey(raw.title) ?? "\u{0}", default: []]
          .append(candidate)
      }
    }

    try adoptIngredients(
      db: db,
      dataJsonPins: dataJsonIngredientPins,
      catalogPins: catalogIngredientPins,
      outcome: &outcome)
    try adoptRecipes(db: db, recipePins: recipePinIndex, outcome: &outcome)
  }

  private static func adoptIngredients(
    db: Database,
    dataJsonPins: [String: [PinIngredientCandidate]],
    catalogPins: [String: [PinIngredientCandidate]],
    outcome: inout BundledDataRefreshOutcome
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
               typical_unit, storage_tip, pairs_with, notes, description,
               category_label, sprite_group, sprite_key
        FROM ingredients WHERE ownership_key IS NULL
        """)
    for row in rows {
      let rowId: Int64 = row["id"]
      let name: String = row["name"]
      let entityRef = "ingredient/legacy:\(rowId)"
      guard let normalized = BundledDataValidator.normalizedKey(name) else {
        try recordDiagnostic(
          db, entityType: "ingredient", entityRef: entityRef, code: "blank_name",
          detail: "ingredient \(rowId) has a blank name and cannot be matched")
        continue
      }
      // Both live hashes are computed per row because the row does not record
      // which writer produced it. Only one projection can match a pin's hash
      // unless two entries genuinely reproduce the row, in which case the keys
      // differ and the row is ambiguous rather than guessed.
      let liveDataJsonHash = CanonicalHash.hash(
        fields: BundleRowProjection.rowFields(row, projection: .dataJsonIngredient))
      let liveCatalogHash = CanonicalHash.hash(
        fields: BundleRowProjection.rowFields(row, projection: .catalogIngredient))
      let matching = (dataJsonPins[normalized] ?? []).filter { $0.contentHash == liveDataJsonHash }
        + (catalogPins[normalized] ?? []).filter { $0.contentHash == liveCatalogHash }
      try adoptRow(
        db, matching: matching.map { ($0.ownershipKey, $0.contentHash) }, table: "ingredients",
        rowId: rowId, entityType: "ingredient", entityRef: entityRef,
        recordAdopted: { outcome.ingredientsAdopted += 1 })
    }
  }

  private static func adoptRecipes(
    db: Database, recipePins: [String: [PinRecipeCandidate]],
    outcome: inout BundledDataRefreshOutcome
  ) throws {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, title, time_minutes, servings, instructions, tags
        FROM recipes
        WHERE ownership_key IS NULL AND source = 'bundled'
        """)
    for row in rows {
      let rowId: Int64 = row["id"]
      let title: String = row["title"]
      let entityRef = "recipe/legacy:\(rowId)"
      guard let normalized = BundledDataValidator.normalizedKey(title) else {
        try recordDiagnostic(
          db, entityType: "recipe", entityRef: entityRef, code: "blank_title",
          detail: "recipe \(rowId) has a blank title and cannot be matched")
        continue
      }
      let liveHash = CanonicalHash.hash(fields: BundleRowProjection.rowFields(row, projection: .recipe))
      let relationships = try Row.fetchAll(
        db,
        sql: """
          SELECT i.name AS name, ri.is_required AS is_required, ri.quantity_grams AS grams
          FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.recipe_id = ?
          """,
        arguments: [rowId])
      let liveFingerprint = recipeFingerprint(rows: relationships)

      let candidates = recipePins[normalized] ?? []
      let matching = candidates.filter {
        $0.contentHash == liveHash && $0.relationshipFingerprint == liveFingerprint
      }
      try adoptRow(
        db, matching: matching.map { ($0.ownershipKey, $0.contentHash) }, table: "recipes",
        rowId: rowId, entityType: "recipe", entityRef: entityRef,
        recordAdopted: { outcome.recipesAdopted += 1 })
    }
  }

  /// Shared adoption decision: exactly one distinct candidate key whose content
  /// matches wins; zero, multi-key, or already-taken candidates get diagnostics.
  private static func adoptRow(
    db: Database,
    matching: [(key: String, hash: String)],
    table: String,
    rowId: Int64,
    entityType: String,
    entityRef: String,
    recordAdopted: () -> Void
  ) throws {
    let candidateKeys = Set(matching.map(\.key))
    if candidateKeys.isEmpty {
      try recordDiagnostic(
        db, entityType: entityType, entityRef: entityRef, code: "unmatched_row",
        detail: "no pinned payload matches this row's content")
      return
    }
    if candidateKeys.count > 1 {
      try recordDiagnostic(
        db, entityType: entityType, entityRef: entityRef, code: "ambiguous_candidates",
        detail:
          "content matches multiple bundle entries: \(candidateKeys.sorted().joined(separator: ", "))")
      return
    }
    let key = candidateKeys.first!
    let hash = matching.first { $0.key == key }!.hash
    let taken: Int = try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM \(table) WHERE ownership_key = ? AND id <> ?",
      arguments: [key, rowId]) ?? 0
    if taken > 0 {
      try recordDiagnostic(
        db, entityType: entityType, entityRef: entityRef, code: "duplicate_adoption_target",
        detail: "another row already owns \(key)")
      return
    }
    try db.execute(
      sql: "UPDATE \(table) SET ownership_key = ?, bundle_content_hash = ? WHERE id = ?",
      arguments: [key, hash, rowId])
    try clearDiagnostics(db, entityType: entityType, entityRef: entityRef)
    recordAdopted()
  }

  // MARK: - Phase 2: apply the current payload

  private static func applyCurrentPayload(
    db: Database, pass: Pass, outcome: inout BundledDataRefreshOutcome
  ) throws {
    try applyIngredients(db: db, pass: pass, outcome: &outcome)
    try applyCatalogIngredients(db: db, pass: pass, outcome: &outcome)
    try applyRecipes(db: db, pass: pass, outcome: &outcome)
  }

  private static func applyIngredients(
    db: Database, pass: Pass, outcome: inout BundledDataRefreshOutcome
  ) throws {
    for (idString, raw) in pass.current.ingredients {
      guard let id = Int(idString) else { continue }
      try upsertIngredient(
        db,
        key: BundleOwnership.ingredientKey(bundleIngredientId: id),
        name: raw.name,
        payloadHash: CanonicalHash.hash(
          fields: BundleRowProjection.dataJsonIngredientFields(raw)),
        writeFields: ingredientWriteFields(from: raw),
        payloadRef: "ingredient/\(id) (\(raw.name))",
        outcome: &outcome,
        recordInserted: { outcome.ingredientsInserted += 1 },
        recordUpdated: { outcome.ingredientsUpdated += 1 })
    }
  }

  private static func applyCatalogIngredients(
    db: Database, pass: Pass, outcome: inout BundledDataRefreshOutcome
  ) throws {
    for raw in pass.catalog {
      try upsertIngredient(
        db,
        key: BundleOwnership.usdaIngredientKey(fdcId: raw.fdcId),
        name: raw.name,
        payloadHash: CanonicalHash.hash(
          fields: BundleRowProjection.catalogIngredientFields(raw)),
        writeFields: catalogWriteFields(from: raw),
        payloadRef: "usda/\(raw.fdcId) (\(raw.name))",
        outcome: &outcome,
        recordInserted: { outcome.ingredientsInserted += 1 },
        recordUpdated: { outcome.ingredientsUpdated += 1 })
    }
  }

  /// One ingredient upsert decision shared by the data.json and catalog passes:
  /// - owned row whose live content equals the payload: marker-only touch at most
  /// - owned row carrying its stored hash while the payload changed: update in place
  /// - owned row whose live content differs from its stored hash: modified, skip
  /// - no owned row and no same-named row at all: insert new
  /// - no owned row but an unowned name-twin exists: blocked, diagnostic
  /// - no owned row but the name is held by a differently-owned row: blocked, diagnostic
  private static func upsertIngredient(
    db: Database,
    key: String,
    name: String,
    payloadHash: String,
    writeFields: [String: (any DatabaseValueConvertible)?],
    payloadRef: String,
    outcome: inout BundledDataRefreshOutcome,
    recordInserted: () -> Void,
    recordUpdated: () -> Void
  ) throws {
    let owned = try Row.fetchOne(
      db,
      sql: "SELECT id, bundle_content_hash FROM ingredients WHERE ownership_key = ?",
      arguments: [key])
    if let owned {
      let rowId: Int64 = owned["id"]
      let storedHash: String? = owned["bundle_content_hash"]
      let liveHash = try liveIngredientHash(db, rowId: rowId, ownershipKey: key)
      if liveHash == payloadHash {
        if storedHash != payloadHash {
          // Content already matches the current payload; refresh the marker only.
          try db.execute(
            sql: "UPDATE ingredients SET bundle_content_hash = ? WHERE id = ?",
            arguments: [payloadHash, rowId])
        }
        try clearDiagnostics(db, entityType: "ingredient", entityRef: key)
        return
      }
      if storedHash != nil, liveHash == storedHash {
        try writeIngredientContent(db, rowId: rowId, fields: writeFields, hash: payloadHash)
        try clearDiagnostics(db, entityType: "ingredient", entityRef: key)
        recordUpdated()
        return
      }
      try recordDiagnostic(
        db, entityType: "ingredient", entityRef: key, code: "modified_row",
        detail:
          "\(payloadRef): installed content no longer matches what the bundle wrote; left untouched")
      return
    }

    // No owned row. A same-named unowned row is legacy content that adoption
    // refused (or that predates this feature); never steal it silently.
    let unownedTwin: Row? = try Row.fetchOne(
      db,
      sql: "SELECT id FROM ingredients WHERE ownership_key IS NULL AND name = ? COLLATE NOCASE",
      arguments: [name])
    if unownedTwin != nil {
      try recordDiagnostic(
        db, entityType: "ingredient", entityRef: key, code: "blocked_by_unadopted_row",
        detail: "\(payloadRef): an unadopted row with the same name exists; it stays unowned")
      return
    }
    // A name held by a row owned by a different bundle entry would make this
    // insert hit the name UNIQUE constraint and fail the pass; skip and explain.
    let conflictingNames: Int = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM ingredients
        WHERE name = ? COLLATE NOCASE AND ownership_key IS NOT NULL AND ownership_key != ?
        """,
      arguments: [name, key]) ?? 0
    if conflictingNames > 0 {
      try recordDiagnostic(
        db, entityType: "ingredient", entityRef: key, code: "name_conflict",
        detail:
          "\(payloadRef): the name is held by a row owned by another bundle entry; no second row was created"
      )
      return
    }
    try insertIngredient(db, fields: writeFields, key: key, hash: payloadHash)
    try clearDiagnostics(db, entityType: "ingredient", entityRef: key)
    recordInserted()
  }

  private static func applyRecipes(
    db: Database, pass: Pass, outcome: inout BundledDataRefreshOutcome
  ) throws {
    // Payload ingredient id -> owned row id. New ingredients were inserted in the
    // ingredient passes, so every resolvable pair resolves here.
    var ownedIngredientsByKey: [String: Int64] = [:]
    for row in try Row.fetchAll(
      db,
      sql: "SELECT id, ownership_key FROM ingredients WHERE ownership_key IS NOT NULL"
    ) {
      ownedIngredientsByKey[row["ownership_key"]] = row["id"]
    }

    for raw in pass.current.recipes {
      let key = BundleOwnership.recipeKey(bundleRecipeId: raw.id)
      let payloadHash = CanonicalHash.hash(fields: BundleRowProjection.recipeFields(raw))

      // Resolve every relationship before touching the recipe row; an unresolved
      // pair means the recipe cannot be written as a whole.
      var resolvedPairs:
        [(ingredientRowId: Int64, isRequired: Bool, grams: Double, display: String)] = []
      var unresolved: [Int] = []
      for (isRequired, pairs) in [(true, raw.requiredIngredients), (false, raw.optionalIngredients)] {
        for pair in pairs {
          if let rowId = ownedIngredientsByKey[
            BundleOwnership.ingredientKey(bundleIngredientId: pair.id)]
          {
            resolvedPairs.append(
              (
                rowId, isRequired, pair.grams,
                BundledDataLoader.formatDisplayQuantity(
                  grams: pair.grams, ingredientId: pair.id, ingredients: pass.current.ingredients)
              ))
          } else {
            unresolved.append(pair.id)
          }
        }
      }
      if !unresolved.isEmpty {
        try recordDiagnostic(
          db, entityType: "recipe", entityRef: key, code: "unresolved_ingredient_dependency",
          detail:
            "recipe \(raw.id) (\(raw.title)): no owned ingredient rows for ids \(unresolved.sorted())")
        continue
      }

      let owned = try Row.fetchOne(
        db,
        sql: "SELECT id, bundle_content_hash FROM recipes WHERE ownership_key = ?",
        arguments: [key])
      if let owned {
        let rowId: Int64 = owned["id"]
        let storedHash: String? = owned["bundle_content_hash"]
        let liveHash = try liveRecipeHash(db, rowId: rowId)
        if liveHash == payloadHash {
          if storedHash != payloadHash {
            try db.execute(
              sql: "UPDATE recipes SET bundle_content_hash = ? WHERE id = ?",
              arguments: [payloadHash, rowId])
          }
          try clearDiagnostics(db, entityType: "recipe", entityRef: key)
          continue
        }
        if storedHash != nil, liveHash == storedHash {
          try writeRecipeContent(
            db, rowId: rowId, raw: raw, hash: payloadHash, pairs: resolvedPairs)
          try clearDiagnostics(db, entityType: "recipe", entityRef: key)
          outcome.recipesUpdated += 1
          continue
        }
        try recordDiagnostic(
          db, entityType: "recipe", entityRef: key, code: "modified_row",
          detail:
            "recipe \(raw.id) (\(raw.title)): installed content no longer matches what the bundle wrote; left untouched")
        continue
      }

      // No owned row: a same-title unowned recipe blocks the insert.
      let unownedTwin: Row? = try Row.fetchOne(
        db,
        sql: """
          SELECT id FROM recipes
          WHERE ownership_key IS NULL AND source = 'bundled'
            AND LOWER(TRIM(title)) = ?
          """,
        arguments: [BundledDataValidator.normalizedKey(raw.title) ?? "\u{0}"])
      if unownedTwin != nil {
        try recordDiagnostic(
          db, entityType: "recipe", entityRef: key, code: "blocked_by_unadopted_row",
          detail:
            "recipe \(raw.id) (\(raw.title)): an unadopted row with the same title exists; it stays unowned")
        continue
      }
      let newRowId = try insertRecipe(db, raw: raw, key: key, hash: payloadHash)
      try rewriteRecipeIngredients(db, recipeRowId: newRowId, pairs: resolvedPairs)
      try clearDiagnostics(db, entityType: "recipe", entityRef: key)
      outcome.recipesInserted += 1
    }
  }

  // MARK: - Phase 3: removals

  private static func recordRemovals(db: Database, pass: Pass) throws {
    let payloadRecipeKeys = Set(
      pass.current.recipes.map { BundleOwnership.recipeKey(bundleRecipeId: $0.id) })
    for row in try Row.fetchAll(
      db, sql: "SELECT DISTINCT ownership_key FROM recipes WHERE ownership_key IS NOT NULL"
    ) {
      let key: String = row["ownership_key"]
      if !payloadRecipeKeys.contains(key) {
        try recordDiagnostic(
          db, entityType: "recipe", entityRef: key, code: "removed_from_bundle",
          detail: "the current bundle no longer ships this entry; row kept")
      }
    }
    let payloadIngredientKeys = Set(
      pass.current.ingredients.compactMap { idString, _ -> String? in
        Int(idString).map { BundleOwnership.ingredientKey(bundleIngredientId: $0) }
      })
    let payloadCatalogKeys = Set(
      pass.catalog.map { BundleOwnership.usdaIngredientKey(fdcId: $0.fdcId) })
    for row in try Row.fetchAll(
      db, sql: "SELECT DISTINCT ownership_key FROM ingredients WHERE ownership_key IS NOT NULL"
    ) {
      let key: String = row["ownership_key"]
      if !payloadIngredientKeys.contains(key) && !payloadCatalogKeys.contains(key) {
        try recordDiagnostic(
          db, entityType: "ingredient", entityRef: key, code: "removed_from_bundle",
          detail: "the current bundle no longer ships this entry; row kept")
      }
    }
  }

  // MARK: - Phase 4: postconditions

  /// After a pass, every current-payload entry must be owned by exactly one row
  /// whose live content equals the payload's projection — unless a diagnostic
  /// explains the exception. Anything else means the pass has a bug; throw and
  /// let the transaction roll the database back.
  private static func verifyPostConditions(db: Database, pass: Pass) throws {
    var ownedKeysByTable: (recipes: Set<String>, ingredients: Set<String>) = ([], [])
    for row in try Row.fetchAll(
      db, sql: "SELECT ownership_key FROM recipes WHERE ownership_key IS NOT NULL"
    ) {
      ownedKeysByTable.recipes.insert(row["ownership_key"])
    }
    for row in try Row.fetchAll(
      db, sql: "SELECT ownership_key FROM ingredients WHERE ownership_key IS NOT NULL"
    ) {
      ownedKeysByTable.ingredients.insert(row["ownership_key"])
    }

    func hasDiagnostic(_ entityType: String, _ entityRef: String, _ code: String) throws -> Bool {
      let count: Int = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bundle_refresh_diagnostics
          WHERE entity_type = ? AND entity_ref = ? AND code = ?
          """,
        arguments: [entityType, entityRef, code]) ?? 0
      return count > 0
    }

    for raw in pass.current.recipes {
      let key = BundleOwnership.recipeKey(bundleRecipeId: raw.id)
      let entryOk: Bool
      if ownedKeysByTable.recipes.contains(key) {
        let liveHash = try liveRecipeHashByKey(db, key: key)
        // An owned-but-modified row is a legitimate permanent state (user
        // content wins), explained by the diagnostic the pass records when it
        // declines to touch the row.
        entryOk =
          liveHash == CanonicalHash.hash(fields: BundleRowProjection.recipeFields(raw))
          || try hasDiagnostic("recipe", key, "modified_row")
      } else {
        entryOk = try hasDiagnostic("recipe", key, "blocked_by_unadopted_row")
          || try hasDiagnostic("recipe", key, "unresolved_ingredient_dependency")
      }
      if !entryOk {
        throw BundledDataRefreshError.postConditionFailed("recipe entry \(key)")
      }
    }
    for (idString, raw) in pass.current.ingredients {
      guard let id = Int(idString) else { continue }
      let key = BundleOwnership.ingredientKey(bundleIngredientId: id)
      let entryOk: Bool
      if ownedKeysByTable.ingredients.contains(key) {
        let liveHash = try liveIngredientHashByKey(db, key: key)
        entryOk =
          liveHash == CanonicalHash.hash(fields: BundleRowProjection.dataJsonIngredientFields(raw))
          || try hasDiagnostic("ingredient", key, "modified_row")
      } else {
        entryOk = try hasDiagnostic("ingredient", key, "blocked_by_unadopted_row")
          || try hasDiagnostic("ingredient", key, "name_conflict")
      }
      if !entryOk {
        throw BundledDataRefreshError.postConditionFailed("ingredient entry \(key)")
      }
    }
    for raw in pass.catalog {
      let key = BundleOwnership.usdaIngredientKey(fdcId: raw.fdcId)
      let entryOk: Bool
      if ownedKeysByTable.ingredients.contains(key) {
        let liveHash = try liveIngredientHashByKey(db, key: key)
        entryOk =
          liveHash == CanonicalHash.hash(fields: BundleRowProjection.catalogIngredientFields(raw))
          || try hasDiagnostic("ingredient", key, "modified_row")
      } else {
        entryOk = try hasDiagnostic("ingredient", key, "blocked_by_unadopted_row")
          || try hasDiagnostic("ingredient", key, "name_conflict")
      }
      if !entryOk {
        throw BundledDataRefreshError.postConditionFailed("catalog entry \(key)")
      }
    }
  }

  // MARK: - Live hashing

  private static func liveRecipeHash(db: Database, rowId: Int64) throws -> String {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [rowId])
    else {
      throw BundledDataRefreshError.postConditionFailed("recipe row \(rowId) disappeared")
    }
    return CanonicalHash.hash(fields: BundleRowProjection.rowFields(row, projection: .recipe))
  }

  private static func liveRecipeHashByKey(db: Database, key: String) throws -> String {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE ownership_key = ?", arguments: [key])
    else {
      throw BundledDataRefreshError.postConditionFailed("recipe \(key) disappeared")
    }
    return CanonicalHash.hash(fields: BundleRowProjection.rowFields(row, projection: .recipe))
  }

  private static func liveIngredientHash(db: Database, rowId: Int64, ownershipKey: String) throws
    -> String
  {
    guard let row = try Row.fetchOne(
      db, sql: "SELECT * FROM ingredients WHERE id = ?", arguments: [rowId])
    else {
      throw BundledDataRefreshError.postConditionFailed("ingredient row \(rowId) disappeared")
    }
    return CanonicalHash.hash(
      fields: BundleRowProjection.rowFields(row, projection: ingredientProjection(for: ownershipKey)))
  }

  private static func liveIngredientHashByKey(db: Database, key: String) throws -> String {
    guard let row = try Row.fetchOne(
      db, sql: "SELECT * FROM ingredients WHERE ownership_key = ?", arguments: [key])
    else {
      throw BundledDataRefreshError.postConditionFailed("ingredient \(key) disappeared")
    }
    return CanonicalHash.hash(
      fields: BundleRowProjection.rowFields(row, projection: ingredientProjection(for: key)))
  }

  /// Provenance by key namespace: usda.fdc/* rows were written by the catalog
  /// importer, fridgeluck.bundle.ingredient/* rows by the data.json loader.
  private static func ingredientProjection(for ownershipKey: String)
    -> BundleRowProjection.RowSource
  {
    ownershipKey.hasPrefix("usda.") ? .catalogIngredient : .dataJsonIngredient
  }

  // MARK: - Write helpers

  private static func ingredientWriteFields(from raw: IngredientArray)
    -> [String: (any DatabaseValueConvertible)?]
  {
    [
      "name": raw.name,
      "calories": raw.calories,
      "protein": raw.protein,
      "carbs": raw.carbs,
      "fat": raw.fat,
      "fiber": raw.fiber,
      "sugar": raw.sugar,
      "sodium": raw.sodium,
      "typical_unit": raw.typicalUnit,
      "storage_tip": raw.storageTip,
      "pairs_with": nil,
      "notes": nil,
      "description": nil,
      "category_label": nil,
      "sprite_group": nil,
      "sprite_key": nil,
    ]
  }

  private static func catalogWriteFields(from raw: LegacyCatalogIngredient)
    -> [String: (any DatabaseValueConvertible)?]
  {
    [
      "name": raw.name,
      "calories": raw.calories,
      "protein": raw.protein,
      "carbs": raw.carbs,
      "fat": raw.fat,
      "fiber": raw.fiber,
      "sugar": raw.sugar,
      "sodium": raw.sodium,
      "typical_unit": nil,
      "storage_tip": nil,
      "pairs_with": nil,
      "notes": raw.notes,
      "description": raw.description,
      "category_label": raw.categoryLabel,
      "sprite_group": raw.spriteGroup,
      "sprite_key": raw.spriteKey,
    ]
  }

  private static let ingredientContentColumns = [
    "name", "calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium",
    "typical_unit", "storage_tip", "pairs_with", "notes", "description",
    "category_label", "sprite_group", "sprite_key",
  ]

  private static func ingredientArguments(
    fields: [String: (any DatabaseValueConvertible)?], key: String?, hash: String?, rowId: Int64?
  ) -> StatementArguments {
    var arguments: [String: (any DatabaseValueConvertible)?] = [:]
    for column in ingredientContentColumns {
      arguments[column] = fields[column] ?? nil
    }
    arguments["key"] = key
    arguments["hash"] = hash
    arguments["id"] = rowId
    return StatementArguments(arguments)
  }

  private static func writeIngredientContent(
    db: Database, rowId: Int64, fields: [String: (any DatabaseValueConvertible)?], hash: String
  ) throws {
    let assignments = ingredientContentColumns.map { "\($0) = :\($0)" }.joined(separator: ", ")
    try db.execute(
      sql: "UPDATE ingredients SET \(assignments), bundle_content_hash = :hash WHERE id = :id",
      arguments: ingredientArguments(fields: fields, key: nil, hash: hash, rowId: rowId))
  }

  private static func insertIngredient(
    db: Database, fields: [String: (any DatabaseValueConvertible)?], key: String, hash: String
  ) throws {
    let columns = ingredientContentColumns.joined(separator: ", ")
    let placeholders = ingredientContentColumns.map { ":\($0)" }.joined(separator: ", ")
    try db.execute(
      sql: """
        INSERT INTO ingredients (\(columns), ownership_key, bundle_content_hash)
        VALUES (\(placeholders), :key, :hash)
        """,
      arguments: ingredientArguments(fields: fields, key: key, hash: hash, rowId: nil))
  }

  private static func writeRecipeContent(
    db: Database,
    rowId: Int64,
    raw: RecipeArray,
    hash: String,
    pairs: [(ingredientRowId: Int64, isRequired: Bool, grams: Double, display: String)]
  ) throws {
    try db.execute(
      sql: """
        UPDATE recipes
        SET title = :title, time_minutes = :time, servings = :servings,
            instructions = :instructions, tags = :tags, bundle_content_hash = :hash
        WHERE id = :id
        """,
      arguments: [
        "title": raw.title, "time": raw.timeMinutes, "servings": raw.servings,
        "instructions": raw.instructions, "tags": raw.tagBitmask, "hash": hash, "id": rowId,
      ])
    try rewriteRecipeIngredients(db, recipeRowId: rowId, pairs: pairs)
  }

  private static func insertRecipe(
    db: Database, raw: RecipeArray, key: String, hash: String
  ) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source,
                             ownership_key, bundle_content_hash)
        VALUES (:title, :time, :servings, :instructions, :tags, 'bundled', :key, :hash)
        """,
      arguments: [
        "title": raw.title, "time": raw.timeMinutes, "servings": raw.servings,
        "instructions": raw.instructions, "tags": raw.tagBitmask, "key": key, "hash": hash,
      ])
    return db.lastInsertRowId
  }

  private static func rewriteRecipeIngredients(
    db: Database,
    recipeRowId: Int64,
    pairs: [(ingredientRowId: Int64, isRequired: Bool, grams: Double, display: String)]
  ) throws {
    try db.execute(
      sql: "DELETE FROM recipe_ingredients WHERE recipe_id = ?", arguments: [recipeRowId])
    for pair in pairs {
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          recipeRowId, pair.ingredientRowId, pair.isRequired, pair.grams, pair.display,
        ])
    }
  }

  // MARK: - Fingerprints, diagnostics, state

  private static func pinRecipeFingerprint(
    required: [(id: Int, grams: Double)],
    optional: [(id: Int, grams: Double)],
    ingredients: [String: IngredientArray]
  ) -> String {
    let lines = (required.map { ($0.id, true, $0.grams) } + optional.map { ($0.id, false, $0.grams) })
      .map { (id, required, grams) -> String in
        let name = ingredients[String(id)]?.name ?? "#\(id)"
        return [
          BundledDataValidator.normalizedKey(name) ?? "\u{0}",
          required ? "required" : "optional",
          CanonicalHash.real(grams),
        ].joined(separator: "\u{1F}")
      }
      .sorted()
    return lines.joined(separator: "\n")
  }

  private static func recipeFingerprint(rows: [Row]) -> String {
    let lines = rows.map { row -> String in
      let name: String = row["name"]
      let required: Bool = row["is_required"]
      let grams: Double = row["grams"]
      return [
        BundledDataValidator.normalizedKey(name) ?? "\u{0}",
        required ? "required" : "optional",
        CanonicalHash.real(grams),
      ].joined(separator: "\u{1F}")
    }
    return lines.sorted().joined(separator: "\n")
  }

  private static func recordDiagnostic(
    db: Database, entityType: String, entityRef: String, code: String, detail: String
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bundle_refresh_diagnostics (entity_type, entity_ref, code, detail, created_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(entity_type, entity_ref, code) DO UPDATE SET
          detail = excluded.detail,
          created_at = CURRENT_TIMESTAMP
        """,
      arguments: [entityType, entityRef, code, detail])
  }

  private static func clearDiagnostics(db: Database, entityType: String, entityRef: String) throws {
    try db.execute(
      sql: "DELETE FROM bundle_refresh_diagnostics WHERE entity_type = ? AND entity_ref = ?",
      arguments: [entityType, entityRef])
  }

  private static func fetchStateValue(_ db: Database, key: String) throws -> String? {
    try String.fetchOne(
      db, sql: "SELECT value FROM bundled_recipe_state WHERE key = ?", arguments: [key])
  }

  private static func setStateValue(_ db: Database, key: String, value: String) throws {
    try BundledDataLoader.upsertBundledRecipeState(db, key: key, value: value)
  }

  private static func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
  }
}
