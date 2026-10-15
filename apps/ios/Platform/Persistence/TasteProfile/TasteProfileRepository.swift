import Foundation
import GRDB

import FLFeatureLogic

/// Reads the taste tables into per-feature evidence aggregates, computes the profile
/// page through `TasteStatementBuilder`, and applies the user's corrections ("This is
/// wrong", "Don't ask again", reopen) through the tables `TasteEventStore` created.
///
/// Nothing here adds tables: statement state goes through `taste_statements`
/// (`TasteEventStore.upsertStatement` or direct SQL on the same columns), corrections
/// are logged as `correction_applied` events in `taste_events`
/// (docs/spec/taste/contracts/taste-event.schema.json), and restriction sentences are
/// rebuilt from `health_profile`, which is why they survive a full taste-log reset.
final class TasteProfileRepository: Sendable {
  private let dbQueue: DatabaseQueue
  private let store: TasteEventStore

  init(dbQueue: DatabaseQueue, store: TasteEventStore) {
    self.dbQueue = dbQueue
    self.store = store
  }

  // MARK: - Profile computation

  /// Recomputes the whole profile page from the event log and the health profile, and
  /// persists statement state. Returns the computed page.
  @discardableResult
  func recomputeProfile(now: Date = Date()) async throws -> TasteProfilePage {
    let evidence = try await loadEvidence()
    // The stored restriction rows are rebuilt from `health_profile` on every pass, so
    // the freshly built seeds replace them instead of stacking on top.
    let storedSeeds = try store.statements().map(Self.seed(from:))
      .filter { $0.layer != .restriction }
    let restrictions = try await restrictionSeeds(now: now)
    let page = TasteStatementBuilder.build(
      evidence: evidence, seeds: storedSeeds + restrictions, now: now)
    try await persist(page: page, now: now)
    try await persistRestrictions(restrictions, now: now)
    let finalSeeds = try store.statements().map(Self.seed(from:))
      .filter { $0.layer != .restriction }
    return TasteStatementBuilder.build(
      evidence: evidence, seeds: finalSeeds + restrictions, now: now)
  }

  /// Loads the profile page without persisting (the read path for the view model).
  /// Restrictions come from `health_profile` directly, so they render even before the
  /// first persisted recompute.
  func loadProfile(now: Date = Date()) async throws -> TasteProfilePage {
    let evidence = try await loadEvidence()
    // The stored restriction rows are rebuilt from `health_profile` here, so the
    // freshly built seeds replace them instead of stacking on top.
    let seeds = try store.statements().map(Self.seed(from:))
      .filter { $0.layer != .restriction }
    let restrictions = try await restrictionSeeds(now: now)
    return TasteStatementBuilder.build(
      evidence: evidence, seeds: seeds + restrictions, now: now)
  }

  // MARK: - Corrections

  /// "This is wrong": the statement is kept, marked rejected, and never re-learned
  /// from the same evidence
  /// (docs/spec/taste/contracts/profile-statement.schema.json `state: rejected`).
  func markWrong(statementId: String, now: Date = Date()) async throws {
    guard var statement = try store.statement(id: statementId) else { return }
    statement.state = .rejected
    statement.updatedAt = now
    try store.upsertStatement(statement)
    try logCorrection(statementId: statementId, action: "this_is_wrong", now: now)
  }

  /// "Don't ask again": mutes the statement until `mutedUntil` (default 90 days) and,
  /// for an inferred feature statement, records a pinned override with rank effect
  /// (docs/spec/taste/SPEC.md §4; the contract's pinned-muted example pins
  /// `pinnedValue: -6`).
  func markDontAskAgain(
    statementId: String, mutedUntil until: Date? = nil, now: Date = Date()
  ) async throws {
    guard var statement = try store.statement(id: statementId) else { return }
    let until = until ?? now.addingTimeInterval(90 * 86_400)
    statement.state = .muted
    statement.mutedUntil = until
    statement.updatedAt = now
    try store.upsertStatement(statement)

    if let featureKey = statement.featureKey, statement.layer == .inferred {
      let names = try await ingredientNames()
      let pinId = TasteStatementIdentity.statementId(
        featureKey: featureKey, templateId: "pinned.dont_ask_again")
      let existingPin = try store.statement(id: pinId)
      let pin = TasteProfileStatement(
        id: pinId,
        layer: .pinned,
        featureKind: statement.featureKind,
        featureKey: featureKey,
        templateId: "pinned.dont_ask_again",
        numerator: nil,
        denominator: nil,
        state: .muted,
        mutedUntil: until,
        pinnedValue: -6.0,
        lastEvidenceAt: now,
        createdAt: existingPin?.createdAt ?? now,
        updatedAt: now,
        text: "You asked not to hear about \(ingredientName(for: featureKey, names: names)) again for a while.")
      try store.upsertStatement(pin)
    }
    try logCorrection(statementId: statementId, action: "dont_ask_again", now: now)
  }

  /// Reopen: undoes a correction at the user's explicit request. A rejected or muted
  /// statement becomes active again and the next recompute re-evaluates it against
  /// the evidence; reopening a pin removes the pin row and un-mutes the inferred
  /// statements it pinned — the correction record stays in the event log.
  func reopen(statementId: String, now: Date = Date()) async throws {
    guard var statement = try store.statement(id: statementId) else { return }
    if statement.layer == .pinned {
      try await removePin(statement: statement, now: now)
      return
    }
    statement.state = .active
    statement.mutedUntil = nil
    statement.updatedAt = now
    try store.upsertStatement(statement)
    try logCorrection(statementId: statementId, action: "reopen", now: now)
  }

  private func removePin(statement: TasteProfileStatement, now: Date) async throws {
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM taste_statements WHERE id = ?", arguments: [statement.id])
      if let featureKey = statement.featureKey {
        // The inferred statements this pin muted go back to the evidence; a rejected
        // statement stays rejected — that correction was its own decision.
        try db.execute(
          sql: """
            UPDATE taste_statements
            SET state = ?, muted_until = NULL, updated_at = ?
            WHERE layer = 'inferred' AND feature_key = ? AND state = 'muted'
            """,
          arguments: [TasteStatementState.active.rawValue, now, featureKey])
      }
    }
    try logCorrection(statementId: statement.id, action: "reopen", now: now)
  }

  private func logCorrection(statementId: String, action: String, now: Date) throws {
    let event = TasteEventRecord(
      at: now,
      surface: TasteSurface.tasteProfile,
      payload: .correctionApplied(
        TasteCorrectionAppliedPayload(statementId: statementId, action: action, note: nil)))
    try store.append(event)
  }

  // MARK: - Evidence aggregation

  /// Builds per-feature claim evidence from the taste event log. Denominators count
  /// cooked recipes containing the feature — behaviour opportunities, never exposure
  /// counts. Views, opens, and exposure logs never enter here: seeing a recipe is
  /// availability, not preference, and cannot produce a statement
  /// (docs/spec/taste/SPEC.md §2.3).
  private func loadEvidence() async throws -> [TasteFeatureEvidence] {
    let featuresByRecipe = try await recipeFeatures()
    let names = try await ingredientNames()
    let events = try store.allEvents()

    // Ratings that arrive after the cook merge into the cook's transaction window via
    // cookEventId (docs/spec/taste/SPEC.md §2.3).
    var ratingByCookEvent: [String: Int] = [:]
    for event in events where event.kind == .recipeRated {
      // The cook linkage lives on the event row (`cook_event_id`) and is repeated in
      // the payload; either identifies the cook window the rating merges into.
      if case .rated(let payload) = event.payload,
        let cookId = payload.cookEventId ?? event.cookEventId
      {
        ratingByCookEvent[cookId] = payload.rating
      }
    }

    func effectiveRating(of cookEvent: TasteEventRecord) -> Int? {
      guard case .cooked(let payload) = cookEvent.payload else { return nil }
      if let rating = payload.rating { return rating }
      let cookId = cookEvent.cookEventId ?? cookEvent.id
      return ratingByCookEvent[cookId]
    }

    // Low-rating claim: denominator = cooked catalog recipes containing the feature;
    // numerator = those cooked meals rated 2 stars or below.
    var cookDenominator: [String: Int] = [:]
    var lowRatingNumerator: [String: Int] = [:]
    var lastCookByFeature: [String: Date] = [:]
    for event in events where event.kind == .recipeCooked {
      guard let recipe = event.event.recipe,
        recipe.source == TasteRecipeSource.catalog.rawValue,
        let features = featuresByRecipe[recipe.id]
      else { continue }
      let rating = effectiveRating(of: event)
      for ingredientId in features.sorted() {
        let key = "ingredient:\(ingredientId)"
        cookDenominator[key, default: 0] += 1
        if let rating, rating <= 2 {
          lowRatingNumerator[key, default: 0] += 1
        }
        if lastCookByFeature[key] == nil || event.at > lastCookByFeature[key]! {
          lastCookByFeature[key] = event.at
        }
      }
    }

    // Substituted-away claim: numerator = cook transactions where the ingredient was
    // swapped out (motivation preferred or none_available), deduplicated per cook so
    // the numerator can never exceed the denominator.
    var substitutedNumerator: [String: Int] = [:]
    var substitutedCooks: Set<String> = []
    var lastSubstitutionByFeature: [String: Date] = [:]
    for event in events where event.kind == .ingredientSubstituted {
      guard case .substituted(let payload) = event.payload else { continue }
      guard payload.motivation != .recipeRecommended else { continue }
      guard let ingredientId = event.ingredientId else { continue }
      let key = "ingredient:\(ingredientId)"
      let cookKey = payload.cookEventId ?? event.id
      if substitutedCooks.contains("\(key)|\(cookKey)") { continue }
      substitutedCooks.insert("\(key)|\(cookKey)")
      substitutedNumerator[key, default: 0] += 1
      if lastSubstitutionByFeature[key] == nil || event.at > lastSubstitutionByFeature[key]! {
        lastSubstitutionByFeature[key] = event.at
      }
    }

    let keys = Set(cookDenominator.keys).union(substitutedNumerator.keys).sorted()
    var evidence: [TasteFeatureEvidence] = []
    for key in keys {
      let name = ingredientName(for: key, names: names)
      let denominator = cookDenominator[key] ?? 0
      evidence.append(
        TasteFeatureEvidence(
          claim: .lowRating, featureKind: .ingredient,
          featureKey: key, featureName: name,
          numerator: lowRatingNumerator[key] ?? 0,
          denominator: denominator,
          lastEvidenceAt: lastCookByFeature[key]))
      if let subCount = substitutedNumerator[key], subCount > 0 {
        evidence.append(
          TasteFeatureEvidence(
            claim: .substitutedAway, featureKind: .ingredient,
            featureKey: key, featureName: name,
            numerator: subCount,
            denominator: max(denominator, subCount),
            lastEvidenceAt: lastSubstitutionByFeature[key]))
      }
    }
    return evidence
  }

  private func recipeFeatures() async throws -> [String: Set<Int64>] {
    try await dbQueue.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT recipe_id, ingredient_id FROM recipe_ingredients")
      var map: [String: Set<Int64>] = [:]
      for row in rows {
        let recipeId: Int64 = row["recipe_id"]
        let ingredientId: Int64 = row["ingredient_id"]
        map[String(recipeId), default: []].insert(ingredientId)
      }
      return map
    }
  }

  private func ingredientNames() async throws -> [Int64: String] {
    try await dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM ingredients")
      var map: [Int64: String] = [:]
      for row in rows {
        map[row["id"]] = row["name"]
      }
      return map
    }
  }

  private func ingredientName(for key: String, names: [Int64: String]) -> String {
    guard key.hasPrefix("ingredient:"),
      let id = Int64(key.dropFirst("ingredient:".count))
    else {
      return key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
    }
    return names[id] ?? "ingredient #\(id)"
  }

  // MARK: - Restrictions

  /// Restriction sentences read from `health_profile`, the restrictions' source of
  /// truth (docs/spec/taste/SPEC.md §4: set at setup, edited in setup only, never
  /// machine-written). This is what makes restrictions survive
  /// `TasteEventStore.deleteAll()`: the taste log resets, the sentences come straight
  /// back from the profile.
  private func restrictionSeeds(now: Date) async throws -> [TasteStatementSeed] {
    guard let profile = try await fetchHealthProfile() else { return [] }
    let names = try await ingredientNames()
    var seeds: [TasteStatementSeed] = []
    let existing = try store.statements(layer: .restriction)
    let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for allergenId in profile.parsedAllergenIds {
      let name = names[allergenId] ?? "ingredient #\(allergenId)"
      let id = TasteStatementIdentity.statementId(
        featureKey: nil, templateId: "restriction.setup.allergy.\(allergenId)")
      seeds.append(
        TasteStatementSeed(
          id: id, layer: .restriction, featureKind: nil, featureKey: nil,
          templateId: "restriction.setup.allergy",
          state: .active,
          createdAt: existingById[id]?.createdAt ?? now, updatedAt: now,
          text: "No \(name). Set at setup, edited in setup only."))
    }
    for diet in profile.parsedDietaryRestrictions.sorted() {
      let id = TasteStatementIdentity.statementId(
        featureKey: nil, templateId: "restriction.setup.diet.\(diet)")
      seeds.append(
        TasteStatementSeed(
          id: id, layer: .restriction, featureKind: nil, featureKey: nil,
          templateId: "restriction.setup.diet",
          state: .active,
          createdAt: existingById[id]?.createdAt ?? now, updatedAt: now,
          text: "No \(diet). Set at setup, edited in setup only."))
    }
    return seeds
  }

  private func fetchHealthProfile() async throws -> HealthProfile? {
    try await dbQueue.read { db in
      guard
        let row = try Row.fetchOne(db, sql: "SELECT * FROM health_profile WHERE id = 1")
      else { return nil }
      let restrictions: String = row["dietary_restrictions"]
      let allergens: String = row["allergen_ingredient_ids"]
      var profile = HealthProfile.default
      profile.dietaryRestrictions = restrictions
      profile.allergenIngredientIds = allergens
      return profile
    }
  }

  // MARK: - Persistence

  /// Writes the computed page: upserts every statement, then prunes inferred rows the
  /// evidence no longer produces — except rejected, muted and confirmed rows, which
  /// are user state, not machine state.
  private func persist(page: TasteProfilePage, now: Date) async throws {
    let retainedIds = page.statements.map(\.id)
    try await dbQueue.write { db in
      for statement in page.statements {
        try Self.upsert(statement, in: db)
      }
      if retainedIds.isEmpty {
        try db.execute(
          sql: """
            DELETE FROM taste_statements
            WHERE layer = 'inferred' AND state IN ('active', 'expired')
            """)
      } else {
        let placeholders = retainedIds.map { _ in "?" }.joined(separator: ",")
        try db.execute(
          sql: """
            DELETE FROM taste_statements
            WHERE layer = 'inferred' AND state IN ('active', 'expired')
            AND id NOT IN (\(placeholders))
            """,
          arguments: StatementArguments(retainedIds))
      }
    }
  }

  /// Writes restriction rows so they exist in `taste_statements` like every other
  /// layer; recompute refreshes them in place, preserving first-creation dates.
  private func persistRestrictions(
    _ restrictions: [TasteStatementSeed], now: Date
  ) async throws {
    try await dbQueue.write { db in
      for seed in restrictions {
        try Self.upsert(TasteProfileStatementValue(from: seed), in: db)
      }
    }
  }

  private static func seed(from statement: TasteProfileStatement) -> TasteStatementSeed {
    TasteStatementSeed(
      id: statement.id,
      layer: TasteProfileStatementLayer(rawValue: statement.layer.rawValue)!,
      featureKind: statement.featureKind.map {
        TasteProfileFeatureKind(rawValue: $0.rawValue)!
      },
      featureKey: statement.featureKey, templateId: statement.templateId,
      numerator: statement.numerator, denominator: statement.denominator,
      state: TasteProfileStatementState(rawValue: statement.state.rawValue)!,
      mutedUntil: statement.mutedUntil, pinnedValue: statement.pinnedValue,
      lastEvidenceAt: statement.lastEvidenceAt, createdAt: statement.createdAt,
      updatedAt: statement.updatedAt, text: statement.text)
  }

  private static func upsert(_ statement: TasteProfileStatementValue, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO taste_statements
          (id, layer, feature_kind, feature_key, template_id, numerator, denominator,
           state, muted_until, pinned_value, last_evidence_at, created_at, updated_at, text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          layer = excluded.layer, feature_kind = excluded.feature_kind,
          feature_key = excluded.feature_key, template_id = excluded.template_id,
          numerator = excluded.numerator, denominator = excluded.denominator,
          state = excluded.state, muted_until = excluded.muted_until,
          pinned_value = excluded.pinned_value,
          last_evidence_at = excluded.last_evidence_at,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          text = excluded.text
        """,
      arguments: [
        statement.id, statement.layer.rawValue, statement.featureKind?.rawValue,
        statement.featureKey, statement.templateId, statement.numerator,
        statement.denominator, statement.state.rawValue, statement.mutedUntil,
        statement.pinnedValue, statement.lastEvidenceAt, statement.createdAt,
        statement.updatedAt, statement.text,
      ])
  }
}
