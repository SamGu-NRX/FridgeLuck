import Foundation
import GRDB

import FLFeatureLogic

/// Stored preference for the learned residual layer on recommendation pools.
///
/// The shipped default follows the committed gate
/// (`evaluation/taste-lab/results/catalog-v2-gate.md`): over the shipped
/// 763-recipe bundle-v2 catalog the learned arm's NDCG@10 delta CI spans zero
/// on seed 7 ([-0.0034, +0.0078]) and top-10 churn runs 3-5x the legacy band,
/// so the offline rerun did NOT confirm the layer as "safe and at least as
/// good" at the standard the legacy-catalog gate set. The ranker therefore
/// ships behind this stored preference, defaulting off; re-gate with the rule
/// stated in the gate report before flipping the default.
enum TasteResidualSettings {
  static let storageKey = "taste.residual_ranker.enabled"

  /// Gate decision 2026-10-15: default off (see the gate report).
  static let builtInDefault = false

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: storageKey) as? Bool ?? builtInDefault
  }
}

/// Applies the learned residual ranker to a rule-scored recommendation pool
/// and logs the render as a taste exposure.
///
/// Pipeline per `apply`: log the exposure (shown slate + full feasible set) —
/// always, because skip/view evidence resolves against it and its value is
/// independent of whether the learned layer reorders (docs/spec/taste/SPEC.md
/// §2.4) — then, when enabled, rebuild the engine from the event log and
/// reorder the pool by rule score + learned contribution. The learned layer
/// can only reorder: it never drops, adds, or re-scores entries, and any
/// failure leaves the rule order untouched.
///
/// Pool identity: catalog entries key on the bundle's catalog id
/// (`rcp-NNNNNN`), legacy-pool entries on their legacy numeric id — the same
/// strings cook and skip events log — so events and pool entries join on one
/// key space, with legacy ids additionally aliased to their superseding
/// catalog rows' features (`TasteCatalogFeatureIndex`).
final class TasteResidualRankingService {
  private let store: TasteEventStore
  private let personalization: PersonalizationService
  private let catalogIndex: TasteCatalogFeatureIndex

  init(
    store: TasteEventStore, personalization: PersonalizationService,
    catalogIndex: TasteCatalogFeatureIndex
  ) {
    self.store = store
    self.personalization = personalization
    self.catalogIndex = catalogIndex
  }

  // MARK: - Pool application

  /// Reorders the pool, then logs the exposure. `shownCount` is how many of the
  /// pool the surface actually renders (the logged slate); the feasible set is
  /// the whole pool. Returns the reordered pool — identical membership,
  /// possibly different order. `now` is the evaluation instant.
  func apply(
    to pool: [ScoredRecipe], surface: String, shownCount: Int = 4, now: Date = Date()
  ) -> [ScoredRecipe] {
    guard !pool.isEmpty else { return pool }

    // Reorder first, then log: the exposure's slate must be the order the user
    // actually saw (SPEC 2.4), which is the learned one once the layer is on —
    // otherwise a promoted recipe never accrues skip/view evidence against a
    // slate it appears on, and a demoted one keeps accruing it. Logging after
    // ranking also keeps the current render's exposure out of its own ranking
    // inputs. When the layer is off the two orders coincide.
    let ordered = TasteResidualSettings.isEnabled ? reorder(pool: pool, now: now) : pool

    logExposure(for: ordered, surface: surface, shownCount: shownCount, now: now)

    return ordered
  }

  /// Logs the render through the taste event store (SPEC 2.4): the displayed
  /// slate (the shown prefix of the returned order) plus the full feasible
  /// candidate set. Exposure logging never blocks the render — a failed append
  /// degrades to rule order.
  private func logExposure(
    for pool: [ScoredRecipe], surface: String, shownCount: Int, now: Date
  ) {
    let refs = pool.map(Self.recipeRef(for:))
    let slate = refs.prefix(max(shownCount, 0)).enumerated().map { offset, ref in
      TasteSlateItem(position: offset, recipe: ref)
    }
    let record = TasteExposureRecord(at: now, surface: surface, slate: slate, feasible: refs)
    do {
      try personalization.logExposure(record)
    } catch {
      // Exposure logging is instrumentation, not render state; the dashboard
      // load must not fail because the taste log did.
    }
  }

  /// Rebuilds the residual engine from the full event log and reorders the
  /// pool. Duplicate identity keys (possible only for unsaved generated
  /// drafts sharing a title) skip the learned layer entirely — reordering them
  /// would join unrelated events to one entry.
  private func reorder(pool: [ScoredRecipe], now: Date) -> [ScoredRecipe] {
    let keys = pool.map { Self.eventKey(for: $0.id) }
    guard Set(keys).count == pool.count else { return pool }

    do {
      let events = try store.allEvents().map(\.event)
      let exposures = try store.allExposures().map(\.exposure)
      var ruleScores: [String: Double] = [:]
      for (entry, key) in zip(pool, keys) {
        ruleScores[key] = entry.rankingScore
      }
      let order = Self.ranked(
        poolKeys: keys, ruleScores: ruleScores, events: events, exposures: exposures,
        featureKeysByRecipe: catalogIndex.aliasedFeatureKeysByRecipe,
        nameOf: catalogIndex.nameOf, evalAt: now)
      var entriesByKey: [String: [ScoredRecipe]] = [:]
      for (entry, key) in zip(pool, keys) {
        entriesByKey[key, default: []].append(entry)
      }
      var ordered: [ScoredRecipe] = []
      ordered.reserveCapacity(pool.count)
      for key in order {
        if var bucket = entriesByKey[key], !bucket.isEmpty {
          ordered.append(bucket.removeFirst())
          entriesByKey[key] = bucket.isEmpty ? nil : bucket
        }
      }
      if ordered.count != pool.count { return pool }
      return ordered
    } catch {
      // The learned layer is additive on top of the rule ranker; a failure to
      // read the event log or run the engine leaves the rule order standing.
      return pool
    }
  }

  // MARK: - Ranker core (pure; no database)

  /// The residual ranking over one pool: rule score + learned contribution,
  /// with the engine's deterministic tiebreak. Pure function of the event log,
  /// the exposures, and the feature index — this is the piece the golden
  /// fixtures pin.
  static func ranked(
    poolKeys: [String], ruleScores: [String: Double],
    events: [TasteEvent], exposures: [TasteExposure],
    featureKeysByRecipe: [String: [String]], nameOf: [String: String],
    evalAt: Date
  ) -> [String] {
    var engine = TasteResidualEngine(featureKeysByRecipe: featureKeysByRecipe, nameOf: nameOf)
    engine.ingest(events: events, exposures: exposures, statements: [])
    let entries = engine.rank(
      ruleScores: ruleScores, evalAt: TasteTimestamp.string(from: evalAt))
    var order = entries.map(\.recipeID)
    // The engine ranks every ruleScores key; append anything it returned
    // nothing for (never expected) in rule order so reordering never drops.
    let rankedSet = Set(order)
    for key in poolKeys where !rankedSet.contains(key) {
      order.append(key)
    }
    return order
  }

  // MARK: - Identity

  /// The event-vocabulary key for a scored entry. Catalog entries and legacy
  /// pool entries log distinct id spaces; both appear in the event log as
  /// these strings.
  static func eventKey(for id: ScoredRecipeID) -> String {
    switch id {
    case .catalog(let catalogId): return catalogId
    case .legacy(let legacyId): return String(legacyId)
    case .unsaved(let title): return title
    }
  }

  /// The contract recipe ref an event row logs for a pool entry.
  static func recipeRef(for entry: ScoredRecipe) -> TasteRecipeRef {
    switch entry.id {
    case .catalog(let catalogId):
      return TasteRecipeRef(id: catalogId, source: TasteRecipeSource.catalog.rawValue)
    case .legacy(let legacyId):
      return TasteRecipeRef(id: String(legacyId), source: TasteRecipeSource.catalog.rawValue)
    case .unsaved(let title):
      return TasteRecipeRef(id: title, source: TasteRecipeSource.generated.rawValue)
    }
  }
}
