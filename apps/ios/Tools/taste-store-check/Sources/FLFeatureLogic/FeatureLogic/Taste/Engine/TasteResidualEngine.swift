import CryptoKit
import Foundation

/// taste-residual-v1 — the Swift port of the lab's reference engine
/// (`evaluation/taste-lab/taste_lab/engine.py`), SPEC sections 2 and 4.
///
/// The rated-cook reference math (lazy decay between updates, exposure-share
/// weighting, contribution = d * c * CAP, canonical 6-decimal floats) is
/// byte-compatible with `docs/spec/taste/contracts/check.py`'s `recompute()`.
/// The golden fixtures in `apps/ios/Tests/TasteRanker/Fixtures/` are the
/// acceptance harness: the Swift engine must reproduce the Python engine's
/// ranking order, scores, posterior state, and profile statements exactly.
///
/// Deterministic: same inputs produce identical outputs; no clocks, no RNG.
public struct TasteResidualEngine: Sendable {
  // MARK: Constants (SPEC 2.2, mirrored from taste_lab/constants.py)

  public static let halfLife: [String: Double] = [
    "cook_rating": 60.0, "cook_no_rating": 30.0, "saved": 45.0, "skipped": 14.0,
    "substitution": 45.0, "lechef": 45.0, "open": 7.0, "view": 7.0,
  ]
  public static let strength: [String: Double] = [
    "cook_rating": 1.0, "cook_no_rating": 0.3, "saved": 0.4, "skipped": 0.2,
    "substitution": 0.5, "lechef": 0.4, "open": 0.15, "view": 0.08,
  ]
  public static let cap: [String: Double] = [
    "ingredient": 4.0, "cuisine": 3.0, "technique": 2.0, "time": 2.0,
    "nutrient": 2.0, "spice": 2.0, "tool": 1.0, "other": 1.0,
  ]
  public static let kShrink = 3.0
  public static let globalClamp = 8.0
  public static let exposureFloor = 0.15
  public static let cookNoRatingReward = 0.6
  // Fixed rewards for save/skip evidence (SPEC 2.3, contracts REWARD table);
  // cooks and ratings derive their reward from the rating itself.
  public static let savedReward = 0.75
  public static let skippedReward = 0.15
  public static let profileMinDenominator = 3
  public static let profileMinRatio = 0.6
  public static let staleAfterHalfLives = 3.0

  // MARK: State

  struct Posterior: Sendable {
    var alpha = 1.0
    var beta = 1.0
    var lastUpdate: Date?
    var lastEvidence: Date?
    var lastClass = "cook_rating"
  }

  struct CookWindow: Sendable {
    var recipeId: String
    var exposureShare: Double
    var rating: Int?
    var at: Date
  }

  public private(set) var featureKeysByRecipe: [String: [String]]
  public private(set) var nameOf: [String: String]
  var state: [String: Posterior]
  var seenEventIds: Set<String>
  var cooks: [String: CookWindow]
  var correctedStatementIds: Set<String>
  var rejectedFeatures: Set<String>
  var pinned: [String: TasteStatement]
  var restrictionStatements: [TasteStatement]
  var inputStatements: [String: TasteStatement]
  var cookEventLog: [TasteEvent]

  // MARK: Init

  public init(
    featureKeysByRecipe: [String: [String]], nameOf: [String: String] = [:]
  ) {
    self.featureKeysByRecipe = featureKeysByRecipe.mapValues { Array(Set($0)).sorted() }
    self.nameOf = nameOf
    self.state = [:]
    self.seenEventIds = []
    self.cooks = [:]
    self.correctedStatementIds = []
    self.rejectedFeatures = []
    self.pinned = [:]
    self.restrictionStatements = []
    self.inputStatements = [:]
    self.cookEventLog = []
  }

  // MARK: - Ingestion

  /// Full replay. Events sort by (at, id); duplicates are no-ops.
  public mutating func ingest(
    events: [TasteEvent], exposures: [TasteExposure], statements: [TasteStatement] = []
  ) {
    let exposuresById = Dictionary(
      exposures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    inputStatements = Dictionary(
      statements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for statement in inputStatements.values {
      if statement.layer == "pinned", let key = statement.featureKey {
        pinned[key] = statement
      } else if statement.layer == "restriction" {
        restrictionStatements.append(statement)
      }
    }

    let ordered = events.sorted { lhs, rhs in
      if lhs.at != rhs.at { return lhs.at < rhs.at }
      return lhs.id < rhs.id
    }
    for event in ordered {
      if seenEventIds.contains(event.id) { continue }
      seenEventIds.insert(event.id)
      ingestEvent(event, exposuresById: exposuresById)
    }
    attachEventLog(cookEventLog)
  }

  func share(of event: TasteEvent, exposuresById: [String: TasteExposure]) -> Double? {
    guard let exposureId = event.payload["exposureId"]?.stringValue else { return nil }
    guard let exposure = exposuresById[exposureId] else { return nil }
    // Skips/views/opens only count for slate members (SPEC 9): a recipe
    // nobody was shown is availability, not preference.
    let slateIds = Set(exposure.slate.map { $0.recipe.id })
    guard let recipeId = event.recipe?.id, slateIds.contains(recipeId) else { return nil }
    let denominator = exposure.feasibleCount
    guard denominator > 0 else { return nil }
    return max(Double(exposure.slate.count) / Double(denominator), Self.exposureFloor)
  }

  mutating func update(
    featureKey: String, at: Date, evidenceClass: String, reward: Double, weight: Double
  ) {
    var posterior = state[featureKey] ?? Posterior()
    if let lastUpdate = posterior.lastUpdate {
      let dtDays = at.timeIntervalSince(lastUpdate) / 86400.0
      let d = Self.decay(dtDays: dtDays, halfLife: Self.halfLife[evidenceClass] ?? 60.0)
      posterior.alpha *= d
      posterior.beta *= d
    }
    posterior.alpha += weight * reward
    posterior.beta += weight * (1.0 - reward)
    posterior.lastUpdate = at
    posterior.lastEvidence = at
    posterior.lastClass = evidenceClass
    state[featureKey] = posterior
  }

  mutating func applyReward(
    to featureKeys: [String], at: Date, evidenceClass: String, reward: Double, weight: Double
  ) {
    for featureKey in featureKeys {
      update(
        featureKey: featureKey, at: at, evidenceClass: evidenceClass, reward: reward, weight: weight
      )
    }
  }

  mutating func applyDelta(
    to featureKeys: [String], at: Date, evidenceClass: String, deltaAlpha: Double, deltaBeta: Double
  ) {
    for featureKey in featureKeys {
      var posterior = state[featureKey] ?? Posterior()
      if let lastUpdate = posterior.lastUpdate {
        let dtDays = at.timeIntervalSince(lastUpdate) / 86400.0
        let d = Self.decay(dtDays: dtDays, halfLife: Self.halfLife[evidenceClass] ?? 60.0)
        posterior.alpha *= d
        posterior.beta *= d
      }
      posterior.alpha += deltaAlpha
      posterior.beta += deltaBeta
      posterior.lastUpdate = at
      posterior.lastClass = evidenceClass
      // last_evidence unchanged: the evidence instant is the cook's.
      state[featureKey] = posterior
    }
  }

  mutating func ingestEvent(_ event: TasteEvent, exposuresById: [String: TasteExposure]) {
    let kind = event.kind
    guard let at = Self.parseUTC(event.at) else { return }
    let recipeId = event.recipe?.id
    let features = recipeId.flatMap { featureKeysByRecipe[$0] } ?? []
    let payload = event.payload

    switch kind {
    case "recipe_cooked":
      cookEventLog.append(event)
      let rating = payload["rating"]?.intValue
      // Cook without a logged exposure: fall back to the exposure floor.
      let share = share(of: event, exposuresById: exposuresById) ?? Self.exposureFloor
      if rating == nil {
        applyReward(
          to: features, at: at, evidenceClass: "cook_no_rating", reward: Self.cookNoRatingReward,
          weight: share * Self.strength["cook_no_rating"]!)
      } else {
        applyReward(
          to: features, at: at, evidenceClass: "cook_rating",
          reward: (Double(rating!) - 1.0) / 4.0, weight: share * Self.strength["cook_rating"]!)
      }
      cooks[event.id] = CookWindow(
        recipeId: recipeId ?? "", exposureShare: share, rating: rating, at: at)

    case "recipe_rated":
      let rating = payload["rating"]?.intValue
      guard let rating else { return }
      let reward = (Double(rating) - 1.0) / 4.0
      guard let cookEventId = payload["cookEventId"]?.stringValue, let cook = cooks[cookEventId]
      else {
        // Standalone rating: its own evidence at strength 1.0.
        applyReward(
          to: features, at: at, evidenceClass: "cook_rating", reward: reward,
          weight: Self.strength["cook_rating"]!)
        return
      }
      if cook.rating == nil {
        // Merge into the cook's transaction window: the rating is its own
        // evidence class (cook_rating, strength 1.0) at its own timestamp,
        // with the cook's exposure share; it adds on top of the unrated
        // cook's own no-rating evidence (SPEC 2.3, the contracts recompute
        // model) and moves the evidence instant to the rating.
        applyReward(
          to: featureKeysByRecipe[cook.recipeId] ?? [], at: at, evidenceClass: "cook_rating",
          reward: reward, weight: cook.exposureShare * Self.strength["cook_rating"]!)
        cooks[cookEventId]?.rating = rating
      } else {
        // Stray late rating for an already-rated cook: correction.
        let oldReward = (Double(cook.rating!) - 1.0) / 4.0
        let w = cook.exposureShare * Self.strength["cook_rating"]!
        let delta = w * (reward - oldReward)
        applyDelta(
          to: featureKeysByRecipe[cook.recipeId] ?? [], at: at, evidenceClass: "cook_rating",
          deltaAlpha: delta, deltaBeta: -delta)
        cooks[cookEventId]?.rating = rating
      }

    case "recipe_saved":
      var weight = Self.strength["saved"]!
      if let s = share(of: event, exposuresById: exposuresById) {
        weight = s * weight
      }  // else: saved off-surface (recipe detail): full credit
      applyReward(
        to: features, at: at, evidenceClass: "saved", reward: Self.savedReward, weight: weight)

    case "recipe_unsaved":
      // Reverses a save by applying the save's update with negative weight.
      applyReward(
        to: features, at: at, evidenceClass: "saved", reward: 1.0,
        weight: -1.0 * Self.strength["saved"]!)

    case "recipe_skipped":
      guard let s = share(of: event, exposuresById: exposuresById) else {
        return  // skip against no logged slate is not taste
      }
      applyReward(
        to: features, at: at, evidenceClass: "skipped", reward: Self.skippedReward,
        weight: s * Self.strength["skipped"]!)

    case "ingredient_substituted":
      let motivation = payload["motivation"]?.stringValue
      guard motivation == "preferred" || motivation == "none_available" else { return }
      let away = event.ingredient?.stringValue
      let substitute = payload["substituteIngredientId"]?.stringValue
      let weight = Self.strength["substitution"]!
      for featureKey in features {
        if featureKey == "ingredient:\(away ?? "§none")" {
          update(
            featureKey: featureKey, at: at, evidenceClass: "substitution", reward: 0.0,
            weight: weight)
        } else if featureKey == "ingredient:\(substitute ?? "§none")" {
          update(
            featureKey: featureKey, at: at, evidenceClass: "substitution", reward: 1.0,
            weight: weight)
        }
      }

    case "lechef_feedback":
      let tag = payload["tag"]?.stringValue
      guard tag == "too_bland" || tag == "too_spicy" else { return }
      let reward = tag == "too_bland" ? 1.0 : 0.0
      let spiceFeatures = features.filter { $0.hasPrefix("spice:") }
      applyReward(
        to: spiceFeatures, at: at, evidenceClass: "lechef", reward: reward,
        weight: Self.strength["lechef"]!)

    case "recipe_viewed", "recipe_opened":
      let evidenceClass = kind == "recipe_viewed" ? "view" : "open"
      guard let s = share(of: event, exposuresById: exposuresById) else { return }
      applyReward(
        to: features, at: at, evidenceClass: evidenceClass, reward: 1.0,
        weight: s * Self.strength[evidenceClass]!)

    case "profile_edited":
      guard let featureKey = payload["featureKey"]?.stringValue else { return }
      let op = payload["op"]?.stringValue
      if op == "never_suggest" {
        pinned[featureKey] = TasteStatement(
          id: Self.statementId(featureKey: featureKey, templateId: "pinned.dont_ask_again"),
          layer: "pinned",
          featureKind: String(featureKey.split(separator: ":", maxSplits: 1).first ?? ""),
          featureKey: featureKey,
          templateId: "pinned.dont_ask_again",
          numerator: nil, denominator: nil,
          state: "active", mutedUntil: nil, pinnedValue: -8.0,
          lastEvidenceAt: event.at, createdAt: event.at, updatedAt: event.at,
          text: "You asked not to hear about \(name(of: featureKey)) again.")
      } else if op == "reopen" || op == "remove" {
        pinned.removeValue(forKey: featureKey)
      }

    case "correction_applied":
      let statementId = payload["statementId"]?.stringValue
      if let statementId { correctedStatementIds.insert(statementId) }
      if let statementId, let statement = inputStatements[statementId],
        let featureKey = statement.featureKey
      {
        // Inferred statements regenerate only from the corrected rule set
        // (SPEC 4): the feature stops rendering this replay.
        rejectedFeatures.insert(featureKey)
      }

    default:
      break  // servings_edited: configures, never trains.
    }
  }

  /// The statement layer recomputes numerators/denominators from the cooked
  /// events; ingest fills this automatically.
  mutating func attachEventLog(_ events: [TasteEvent]) {
    cookEventLog = events.sorted { lhs, rhs in
      if lhs.at != rhs.at { return lhs.at < rhs.at }
      return lhs.id < rhs.id
    }
  }

  // MARK: - Contributions and ranking

  /// Posterior decayed to the evaluation instant.
  public func finalState(evalAt: String) -> [String: (
    alpha: Double, beta: Double, lastEvidenceAt: String?
  )] {
    guard let tEval = Self.parseUTC(evalAt) else { return [:] }
    var final: [String: (alpha: Double, beta: Double, lastEvidenceAt: String?)] = [:]
    for (featureKey, posterior) in state {
      var a = posterior.alpha
      var b = posterior.beta
      if let lastUpdate = posterior.lastUpdate {
        let dtDays = tEval.timeIntervalSince(lastUpdate) / 86400.0
        let d = Self.decay(dtDays: dtDays, halfLife: Self.halfLife[posterior.lastClass] ?? 60.0)
        a *= d
        b *= d
      }
      final[featureKey] = (a, b, posterior.lastEvidence.map { Self.isoUTC($0) })
    }
    return final
  }

  public func contributions(evalAt: String) -> [String: Double] {
    var out: [String: Double] = [:]
    for (featureKey, final) in finalState(evalAt: evalAt) {
      out[featureKey] = Self.contributionOf(
        featureKey: featureKey, alpha: final.alpha, beta: final.beta)
    }
    return out
  }

  static func contributionOf(featureKey: String, alpha: Double, beta: Double) -> Double {
    let n = alpha + beta
    guard n > 0 else { return 0.0 }
    let d = 2.0 * (alpha / n) - 1.0
    let c = n / (n + kShrink)
    let featureClass = String(featureKey.split(separator: ":", maxSplits: 1).first ?? "")
    let value = d * c * (cap[featureClass] ?? 1.0)
    return max(-globalClamp, min(globalClamp, value))
  }

  /// ruleScores: the rule ranker's output for this context (the anchor).
  /// Ties break by recipe id ascending, as the checker does.
  public func rank(ruleScores: [String: Double], evalAt: String) -> [TasteRankEntry] {
    let contribs = contributions(evalAt: evalAt)
    var pinnedByRecipe: [String: Double] = [:]
    let tEval = Self.parseUTC(evalAt)
    for (featureKey, statement) in pinned {
      if let mutedUntil = statement.mutedUntil, let mutedAt = Self.parseUTC(mutedUntil),
        let tEval, mutedAt > tEval
      {
        continue
      }
      let value = statement.pinnedValue ?? 0.0
      guard value != 0 else { continue }
      for (recipeId, featureKeys) in featureKeysByRecipe where featureKeys.contains(featureKey) {
        pinnedByRecipe[recipeId, default: 0.0] += value
      }
    }

    var entries: [TasteRankEntry] = []
    for (recipeId, rule) in ruleScores {
      let featureKeys = featureKeysByRecipe[recipeId] ?? []
      let learned = featureKeys.sorted().map { key in
        TasteFeatureContribution(featureKey: key, contribution: contribs[key] ?? 0.0)
      }
      let learnedSum = learned.reduce(0.0) { $0 + $1.contribution }
      // GLOBAL_CLAMP bounds the whole learned sum; pinned values count toward
      // it (SPEC 9: "pinnedValue ... counts toward GLOBAL_CLAMP").
      let totalLearned = max(
        -Self.globalClamp, min(Self.globalClamp, learnedSum + (pinnedByRecipe[recipeId] ?? 0.0)))
      entries.append(
        TasteRankEntry(
          recipeID: recipeId, ruleScore: rule, learnedFeatures: learned,
          // The reported learned contribution is the clamped sum — the same
          // number totalScore adds to the rule anchor (the contracts recompute
          // model reports the applied clamp, not the raw sum).
          learnedContribution: totalLearned, totalScore: rule + totalLearned))
    }
    entries.sort { lhs, rhs in
      if lhs.totalScore != rhs.totalScore { return lhs.totalScore > rhs.totalScore }
      return lhs.recipeID < rhs.recipeID
    }
    return entries
  }

  // MARK: - Profile statements (SPEC section 4)

  public func profile(evalAt: String) -> (
    rendered: [TasteStatement], hidden: [TasteHiddenStatement]
  ) {
    guard let tEval = Self.parseUTC(evalAt) else { return ([], []) }

    var rendered: [TasteStatement] = []
    var hidden: [TasteHiddenStatement] = []

    for statement in restrictionStatements {
      rendered.append(statement)
    }

    // Inferred statements from cooked-recipe evidence.
    struct Bucket {
      var denominator = 0
      var dislikes = 0
      var likes = 0
      var last: String?
    }
    var cookEvidence: [String: Bucket] = [:]
    for event in cookEventLog {
      guard let recipeId = event.recipe?.id else { continue }
      let rating = event.payload["rating"]?.intValue
      for featureKey in featureKeysByRecipe[recipeId] ?? [] {
        var bucket = cookEvidence[featureKey] ?? Bucket()
        bucket.denominator += 1
        if let rating, rating <= 2 { bucket.dislikes += 1 }
        if let rating, rating >= 4 { bucket.likes += 1 }
        bucket.last = event.at
        cookEvidence[featureKey] = bucket
      }
    }

    for featureKey in cookEvidence.keys.sorted() {
      let bucket = cookEvidence[featureKey]!
      let featureClass = String(featureKey.split(separator: ":", maxSplits: 1).first ?? "")
      var stale = bucket.last == nil
      if let last = bucket.last, let lastDate = Self.parseUTC(last) {
        // Staleness decays on the feature's most recent evidence class —
        // check.py: HALF_LIFE[final[fk].lastClass], not a fixed cook_rating
        // half-life.
        let lastClass = state[featureKey]?.lastClass ?? "cook_rating"
        stale =
          tEval.timeIntervalSince(lastDate) / 86400.0
          > Self.staleAfterHalfLives * (Self.halfLife[lastClass] ?? 60.0)
      }
      if bucket.denominator < Self.profileMinDenominator {
        hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "thin-evidence"))
        continue
      }
      if stale {
        hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "stale-evidence"))
        continue
      }
      if rejectedFeatures.contains(featureKey) {
        hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "rejected"))
        continue
      }

      let dislikeRatio = Double(bucket.dislikes) / Double(bucket.denominator)
      let likeRatio = Double(bucket.likes) / Double(bucket.denominator)

      func build(
        templateId: String, numerator: Int, denominator: Int, text: String
      ) -> TasteStatement {
        TasteStatement(
          id: Self.statementId(featureKey: featureKey, templateId: templateId),
          layer: "inferred", featureKind: featureClass, featureKey: featureKey,
          templateId: templateId, numerator: numerator, denominator: denominator,
          state: "active", mutedUntil: nil, pinnedValue: nil,
          lastEvidenceAt: bucket.last, createdAt: evalAt, updatedAt: evalAt, text: text)
      }

      if dislikeRatio >= Self.profileMinRatio {
        // Hedged wording only when every cooked recipe with the feature is in
        // the numerator (few of them); the confident template names both
        // counts for a mixed history.
        let hedged = bucket.dislikes == bucket.denominator && bucket.denominator < 10
        let statement: TasteStatement
        if hedged {
          statement = build(
            templateId: "taste.lowrating.hedged", numerator: bucket.dislikes,
            denominator: bucket.denominator,
            text:
              "You seem to go off \(name(of: featureKey)): the last \(bucket.dislikes) recipes you cooked with it were rated 2 stars or below."
          )
        } else {
          statement = build(
            templateId: "taste.lowrating.confident", numerator: bucket.dislikes,
            denominator: bucket.denominator,
            text:
              "You go off \(name(of: featureKey)): \(bucket.dislikes) of the \(bucket.denominator) recipes you cooked with it were rated 2 stars or below."
          )
        }
        if correctedStatementIds.contains(statement.id) {
          hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "muted"))
        } else {
          rendered.append(statement)
        }
      } else if likeRatio >= Self.profileMinRatio {
        let hedged = bucket.denominator < 10
        let statement: TasteStatement
        if hedged {
          statement = build(
            templateId: "taste.liking.hedged", numerator: bucket.likes,
            denominator: bucket.denominator,
            text:
              "You seem to enjoy \(name(of: featureKey)): it showed up in your higher-rated cooks.")
        } else {
          statement = build(
            templateId: "taste.liking.confident", numerator: bucket.likes,
            denominator: bucket.denominator,
            text:
              "You enjoy \(name(of: featureKey)): \(bucket.likes) of the \(bucket.denominator) recipes you cooked with it were rated 4 stars or more."
          )
        }
        if correctedStatementIds.contains(statement.id) {
          hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "muted"))
        } else {
          rendered.append(statement)
        }
      } else {
        hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "thin-evidence"))
      }
    }

    // Pinned statements: render when active, hide with "muted" while
    // mutedUntil is in the future.
    for (featureKey, statement) in pinned.sorted(by: { $0.key < $1.key }) {
      let muted =
        statement.mutedUntil.flatMap { Self.parseUTC($0) }.map { $0 > tEval } ?? false
      if muted {
        hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: "muted"))
      } else {
        // The lab overrides state to "active" on render.
        rendered.append(
          statement.state == "active"
            ? statement
            : TasteStatement(
              id: statement.id, layer: statement.layer, featureKind: statement.featureKind,
              featureKey: statement.featureKey, templateId: statement.templateId,
              numerator: statement.numerator, denominator: statement.denominator,
              state: "active", mutedUntil: statement.mutedUntil, pinnedValue: statement.pinnedValue,
              lastEvidenceAt: statement.lastEvidenceAt, createdAt: statement.createdAt,
              updatedAt: statement.updatedAt, text: statement.text))
      }
    }

    return (rendered, hidden)
  }

  func name(of featureKey: String) -> String {
    if let name = nameOf[featureKey] { return name }
    let parts = featureKey.split(separator: ":", maxSplits: 1)
    return parts.count > 1 ? String(parts[1]) : featureKey
  }

  // MARK: - Deterministic helpers

  static func decay(dtDays: Double, halfLife: Double) -> Double {
    pow(2.0, -dtDays / halfLife)
  }

  /// Canonical 6-decimal rounding (round-half-even), matching Python's round().
  public static func f6(_ value: Double) -> Double {
    (value * 1_000_000).rounded(.toNearestOrEven) / 1_000_000
  }

  // ISO8601DateFormatter is documented thread-safe; shared for determinism.
  nonisolated(unsafe) static let utcFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  nonisolated(unsafe) static let utcFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  public static func parseUTC(_ string: String) -> Date? {
    utcFormatter.date(from: string) ?? utcFractionalFormatter.date(from: string)
  }

  public static func isoUTC(_ date: Date) -> String {
    utcFormatter.string(from: date)
  }

  /// RFC 4122 UUIDv5 over SHA-1, matching `uuid.uuid5(namespace, name)` with
  /// the lab's namespace `5e6f7081-0000-4e00-8f00-000000000000` so statement
  /// ids match the Python engine byte for byte.
  public static func statementId(featureKey: String, templateId: String) -> String {
    let namespace = UUID(uuidString: "5e6f7081-0000-4e00-8f00-000000000000")!
    var namespaceBytes = [UInt8]()
    var uuid = namespace.uuid
    withUnsafeBytes(of: &uuid) { buffer in
      namespaceBytes.append(contentsOf: buffer)
    }
    let nameData = Data(("\(templateId):\(featureKey)").utf8)
    let digest = Insecure.SHA1.hash(data: Data(namespaceBytes) + nameData)
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
  }
}
