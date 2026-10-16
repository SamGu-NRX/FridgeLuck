#if canImport(CryptoKit)
import CryptoKit
#else
// Linux: swift-crypto provides the same SHA256 API under the Crypto module.
import Crypto
#endif
import Foundation

// MARK: - Display thresholds

/// Display rules for inferred profile statements
/// (docs/spec/taste/SPEC.md §4; constants mirror docs/spec/taste/contracts/check.py).
public enum TasteStatementDisplay {
  /// Render an inferred statement only when the denominator (distinct cooked recipes
  /// containing the feature) reaches this bar.
  public static let minDenominator = 3
  /// Render only when numerator / denominator is at least this ratio.
  public static let minRatio = 0.6
  /// Evidence older than this many class half-lives is stale: strictly greater counts
  /// as stale, exactly at the boundary does not.
  public static let staleAfterHalfLives = 3.0
  /// Hedged wording is reserved for denominators below this bar
  /// (SPEC §4: "hedged wording below 10 denominators, confident above").
  public static let hedgedMaxDenominator = 10
}

// MARK: - Evidence classes

/// The evidence classes that can carry a profile claim. Exposure-only signals
/// (`open`, `view`) are deliberately absent: seeing a recipe is availability, not
/// preference, and must never produce a statement (SPEC §2.3, §4).
public enum TasteEvidenceClass: String, Sendable, CaseIterable {
  /// Cooks with a rating. Half-life 60 days.
  case cookRating = "cook_rating"
  /// Ingredient substitutions away from a feature. Half-life 45 days.

  case substitution

  /// Exponential decay half-life in days (docs/spec/taste/SPEC.md §2.2 constants).
  public var halfLifeDays: Double {
    switch self {
    case .cookRating: 60
    case .substitution: 45
    }
  }
}

// MARK: - Claims

/// The inferred claims the profile can make about one feature. Every claim is an
/// "avoid" claim learned from the cook's own behaviour; there is no claim the event log
/// cannot evidence, and exposure alone can never produce one.
public enum TasteInferredClaim: String, Sendable, CaseIterable {
  /// Cooked recipes containing the feature were rated 2 stars or below.
  case lowRating = "lowrating"
  /// The cook swapped the feature out (motivation `preferred` or `none_available`).
  case substitutedAway = "substituted"

  /// The evidence class this claim is earned in; its half-life gates staleness.
  public var evidenceClass: TasteEvidenceClass {
    switch self {
    case .lowRating: .cookRating
    case .substitutedAway: .substitution
    }
  }

  /// Template id stem (docs/spec/taste/contracts/profile-statement.schema.json
  /// `templateId`): `<stem>.hedged` / `<stem>.confident`.
  public var templateStem: String {
    switch self {
    case .lowRating: "taste.lowrating"
    case .substitutedAway: "taste.substituted"
    }
  }
}

// MARK: - Feature kinds

/// Feature families of the residual ranker, mirrored from
/// docs/spec/taste/SPEC.md §2.1. The pure layer declares its own copy so it stays
/// independent of the persistence layer's types.
public enum TasteProfileFeatureKind: String, Sendable, CaseIterable {
  case ingredient
  case cuisine
  case technique
  case time
  case nutrient
  case spice
  case tool
  case other
}

// MARK: - Builder inputs

/// Per-feature evidence for one claim: the numerator/denominator pair a sentence
/// stands on, plus when the last supporting event happened. The persistence layer
/// computes these from the taste event log; the builder only reads them.
public struct TasteFeatureEvidence: Sendable, Equatable {
  public var claim: TasteInferredClaim
  public var featureKind: TasteProfileFeatureKind?
  public var featureKey: String
  /// Display name of the feature ("coriander"); used in sentence text.
  public var featureName: String
  /// Evidence count for the claim (e.g. cooks rated 2 stars or below).
  public var numerator: Int
  /// Distinct opportunities the numerator is out of (cooked recipes containing the
  /// feature). Availability — exposures, views, opens — never appears here.
  public var denominator: Int
  /// When the most recent supporting event happened; nil means no evidence at all.
  public var lastEvidenceAt: Date?

  public init(
    claim: TasteInferredClaim,
    featureKind: TasteProfileFeatureKind?,
    featureKey: String,
    featureName: String,
    numerator: Int,
    denominator: Int,
    lastEvidenceAt: Date?
  ) {
    self.claim = claim
    self.featureKind = featureKind
    self.featureKey = featureKey
    self.featureName = featureName
    self.numerator = numerator
    self.denominator = denominator
    self.lastEvidenceAt = lastEvidenceAt
  }
}

/// Statement lifecycle state, mirrored from
/// docs/spec/taste/contracts/profile-statement.schema.json.
public enum TasteProfileStatementState: String, Sendable {
  case active
  case confirmed
  /// "This is wrong": kept, never re-learned, shown struck-through.
  case rejected
  /// "Don't ask again" until `mutedUntil`.
  case muted
  /// Evidence went stale or fell below the display bar; revives automatically on
  /// fresh evidence.
  case expired
}

/// Statement layer, mirrored from the contract schema.
public enum TasteProfileStatementLayer: String, Sendable {
  case restriction
  case stated
  case pinned
  case inferred
}

/// An existing statement row passed through the builder: restriction, stated and
/// pinned layers are never machine-written so they flow through unchanged; inferred
/// rows carry correction state the builder must respect.
public struct TasteStatementSeed: Sendable, Equatable {
  public var id: String
  public var layer: TasteProfileStatementLayer
  public var featureKind: TasteProfileFeatureKind?
  public var featureKey: String?
  public var templateId: String
  public var numerator: Int?
  public var denominator: Int?
  public var state: TasteProfileStatementState
  public var mutedUntil: Date?
  public var pinnedValue: Double?
  public var lastEvidenceAt: Date?
  public var createdAt: Date
  public var updatedAt: Date
  public var text: String

  public init(
    id: String,
    layer: TasteProfileStatementLayer,
    featureKind: TasteProfileFeatureKind? = nil,
    featureKey: String? = nil,
    templateId: String,
    numerator: Int? = nil,
    denominator: Int? = nil,
    state: TasteProfileStatementState,
    mutedUntil: Date? = nil,
    pinnedValue: Double? = nil,
    lastEvidenceAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date,
    text: String
  ) {
    self.id = id
    self.layer = layer
    self.featureKind = featureKind
    self.featureKey = featureKey
    self.templateId = templateId
    self.numerator = numerator
    self.denominator = denominator
    self.state = state
    self.mutedUntil = mutedUntil
    self.pinnedValue = pinnedValue
    self.lastEvidenceAt = lastEvidenceAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.text = text
  }
}

// MARK: - Builder outputs

/// One rendered or carried-over profile sentence with the evidence it stands on
/// (docs/spec/taste/contracts/profile-statement.schema.json shape).
public struct TasteProfileStatementValue: Sendable, Equatable {
  public var id: String
  public var layer: TasteProfileStatementLayer
  public var featureKind: TasteProfileFeatureKind?
  public var featureKey: String?
  public var templateId: String
  public var numerator: Int?
  public var denominator: Int?
  public var state: TasteProfileStatementState
  public var mutedUntil: Date?
  public var pinnedValue: Double?
  public var lastEvidenceAt: Date?
  public var createdAt: Date
  public var updatedAt: Date
  public var text: String

  public init(
    id: String,
    layer: TasteProfileStatementLayer,
    featureKind: TasteProfileFeatureKind?,
    featureKey: String?,
    templateId: String,
    numerator: Int?,
    denominator: Int?,
    state: TasteProfileStatementState,
    mutedUntil: Date?,
    pinnedValue: Double?,
    lastEvidenceAt: Date?,
    createdAt: Date,
    updatedAt: Date,
    text: String
  ) {
    self.id = id
    self.layer = layer
    self.featureKind = featureKind
    self.featureKey = featureKey
    self.templateId = templateId
    self.numerator = numerator
    self.denominator = denominator
    self.state = state
    self.mutedUntil = mutedUntil
    self.pinnedValue = pinnedValue
    self.lastEvidenceAt = lastEvidenceAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.text = text
  }

  /// Builds a statement value from a stored seed (pass-through layers, correction
  /// state carried across recomputes).
  public init(from seed: TasteStatementSeed) {
    id = seed.id
    layer = seed.layer
    featureKind = seed.featureKind
    featureKey = seed.featureKey
    templateId = seed.templateId
    numerator = seed.numerator
    denominator = seed.denominator
    state = seed.state
    mutedUntil = seed.mutedUntil
    pinnedValue = seed.pinnedValue
    lastEvidenceAt = seed.lastEvidenceAt
    createdAt = seed.createdAt
    updatedAt = seed.updatedAt
    text = seed.text
  }
}

/// Why an inferred claim is not rendered. Machine-visible, not rendered
/// (docs/spec/taste/SPEC.md §4).
public enum TasteHiddenReason: String, Sendable {
  case thinEvidence = "thin-evidence"
  case staleEvidence = "stale-evidence"

  /// The state an already-stored statement takes while hidden for this reason.
  var statementState: TasteProfileStatementState {
    switch self {
    case .thinEvidence, .staleEvidence: .expired
    }
  }
}

/// A hidden claim: the evidence is real but below the display bars.
public struct TasteHiddenProfileItem: Sendable, Equatable {
  public var featureKey: String
  public var claim: TasteInferredClaim
  public var reason: TasteHiddenReason
  public var numerator: Int
  public var denominator: Int

  public init(
    featureKey: String, claim: TasteInferredClaim, reason: TasteHiddenReason,
    numerator: Int, denominator: Int
  ) {
    self.featureKey = featureKey
    self.claim = claim
    self.reason = reason
    self.numerator = numerator
    self.denominator = denominator
  }
}

/// The full computed profile page: pass-through layers, rendered inferred statements,
/// and the hidden list.
public struct TasteProfilePage: Sendable, Equatable {
  public var statements: [TasteProfileStatementValue]
  public var hidden: [TasteHiddenProfileItem]

  public init(statements: [TasteProfileStatementValue], hidden: [TasteHiddenProfileItem]) {
    self.statements = statements
    self.hidden = hidden
  }

  /// Statements in one layer, in stored order. Expired rows stay in the full trail
  /// (`.statements`) for inspection but are not shown for their layer.
  public func statements(layer: TasteProfileStatementLayer) -> [TasteProfileStatementValue] {
    statements.filter { $0.layer == layer && $0.state != .expired }
  }
}

// MARK: - Statement identity

/// Deterministic statement ids: recomputing the profile over the same evidence must
/// update the same row, so corrections survive recompute. The id is a UUID-shaped
/// digest of a stable namespace, the feature key and the template id.
public enum TasteStatementIdentity {
  /// Builds a deterministic UUID v4-shaped id from the parts that name a statement.
  public static func statementId(featureKey: String?, templateId: String) -> String {
    let namespace = "fridgeluck:taste:statement:v1"
    let material = "\(namespace)|\(featureKey ?? "-")|\(templateId)"
    let digest = SHA256.hash(data: Data(material.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    let uuid = UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
    return uuid.uuidString.lowercased()
  }
}

// MARK: - Builder

/// Pure builder for the taste profile page (docs/spec/taste/SPEC.md §4): turns
/// per-feature evidence aggregates plus the stored statement state into the sentences
/// the profile shows, each with its evidence, and the corrections the user can make.
///
/// Rules implemented here, all pinned by docs/spec/taste/contracts/:
/// - Render an inferred statement only when `denominator >= 3` cooked recipes contain
///   the feature, `numerator / denominator >= 0.6`, and the last evidence is within
///   `3 x` the claim's class half-life.
/// - Hedged wording when the whole evidence is bad and the denominator is below 10;
///   confident wording names both counts otherwise.
/// - "This is wrong" (`rejected`) is kept and never regenerated from the same
///   evidence; "Don't ask again" (`muted`) hides until `mutedUntil` and then returns.
/// - `expired` statements revive automatically when fresh evidence arrives.
public enum TasteStatementBuilder {
  /// Computes the profile page. `now` is the evaluation instant (pass a fixed date in
  /// tests; production passes the current time).
  public static func build(
    evidence: [TasteFeatureEvidence],
    seeds: [TasteStatementSeed],
    now: Date
  ) -> TasteProfilePage {
    var statements: [TasteProfileStatementValue] = []
    var hidden: [TasteHiddenProfileItem] = []

    // Restriction, stated and pinned layers are never machine-written: pass through
    // exactly as stored.
    for seed in seeds where seed.layer != .inferred {
      statements.append(TasteProfileStatementValue(from: seed))
    }

    // Rejected and muted inferred statements survive recompute untouched — "This is
    // wrong" means never re-learned from the same evidence; "Don't ask again" hides
    // until mutedUntil. Both are keyed by their deterministic statement id.
    let rejectedSeeds = seeds.filter { $0.layer == .inferred && $0.state == .rejected }
    let rejectedIds = Set(rejectedSeeds.map(\.id))
    let mutedSeeds = seeds.filter { $0.layer == .inferred && $0.state == .muted }
    // A mute whose `mutedUntil` has lapsed no longer blocks regeneration — the
    // statement comes back from fresh evidence, unlike a rejected one. A seed with no
    // `mutedUntil` at all is treated as still held.
    let heldMuted = mutedSeeds.filter { seed in
      seed.mutedUntil.map { $0 > now } ?? true
    }
    let heldMutedIds = Set(heldMuted.map(\.id))
    let confirmedIds = Set(
      seeds.filter { $0.layer == .inferred && $0.state == .confirmed }.map(\.id))

    for seed in heldMuted {
      // While the mute holds the statement is carried through as stored: not rendered,
      // not regenerated, and not rejected.
      statements.append(TasteProfileStatementValue(from: seed))
    }
    for seed in rejectedSeeds {
      // "This is wrong" is kept as stored — visible in the trail with its correction
      // state, never regenerated from evidence — while it is hidden from rendering.
      statements.append(TasteProfileStatementValue(from: seed))
    }

    for item in evidence {
      let id = TasteStatementIdentity.statementId(
        featureKey: item.featureKey, templateId: item.claim.templateStem)
      if rejectedIds.contains(id) || heldMutedIds.contains(id) {
        continue  // kept as stored above; never regenerated while corrected
      }

      let stale = isStale(item, now: now)
      let belowDenominator = item.denominator < TasteStatementDisplay.minDenominator
      let belowRatio =
        item.denominator == 0
        ? item.numerator > 0
        : Double(item.numerator) / Double(item.denominator) < TasteStatementDisplay.minRatio

      if belowDenominator || belowRatio {
        hidden.append(
          TasteHiddenProfileItem(
            featureKey: item.featureKey, claim: item.claim,
            reason: .thinEvidence, numerator: item.numerator,
            denominator: item.denominator))
        if let seed = seeds.first(where: { $0.id == id }) {
          // The claim had a rendered life once and fell below the bar: mark it expired
          // (it revives automatically if fresh evidence returns).
          statements.append(
            TasteProfileStatementValue(
              id: seed.id, layer: .inferred, featureKind: seed.featureKind,
              featureKey: seed.featureKey, templateId: seed.templateId,
              numerator: seed.numerator, denominator: seed.denominator,
              state: .expired, mutedUntil: nil, pinnedValue: nil,
              lastEvidenceAt: seed.lastEvidenceAt, createdAt: seed.createdAt,
              updatedAt: now, text: seed.text))
        }
        continue
      }

      if stale {
        hidden.append(
          TasteHiddenProfileItem(
            featureKey: item.featureKey, claim: item.claim,
            reason: .staleEvidence, numerator: item.numerator,
            denominator: item.denominator))
        if let seed = seeds.first(where: { $0.id == id }) {
          statements.append(
            TasteProfileStatementValue(
              id: seed.id, layer: .inferred, featureKind: seed.featureKind,
              featureKey: seed.featureKey, templateId: seed.templateId,
              numerator: seed.numerator, denominator: seed.denominator,
              state: .expired, mutedUntil: nil, pinnedValue: nil,
              lastEvidenceAt: seed.lastEvidenceAt, createdAt: seed.createdAt,
              updatedAt: now, text: seed.text))
        }
        continue
      }

      let existing = seeds.first(where: { $0.id == id })
      let hedged =
        item.numerator == item.denominator
        && item.denominator < TasteStatementDisplay.hedgedMaxDenominator
      let templateId =
        hedged ? "\(item.claim.templateStem).hedged" : "\(item.claim.templateStem).confident"
      let createdAt = existing?.createdAt ?? now
      statements.append(
        TasteProfileStatementValue(
          id: id, layer: .inferred, featureKind: item.featureKind,
          featureKey: item.featureKey, templateId: templateId,
          numerator: item.numerator, denominator: item.denominator,
          state: confirmedIds.contains(id) ? .confirmed : .active,
          mutedUntil: nil, pinnedValue: nil, lastEvidenceAt: item.lastEvidenceAt,
          createdAt: createdAt, updatedAt: now,
          text: render(claim: item.claim, name: item.featureName,
            numerator: item.numerator, denominator: item.denominator, hedged: hedged)))
    }

    return TasteProfilePage(statements: statements, hidden: hidden)
  }

  /// Strictly past the staleness boundary counts as stale; exactly at the boundary the
  /// statement still renders ("a sentence appears exactly at its threshold").
  static func isStale(_ item: TasteFeatureEvidence, now: Date) -> Bool {
    guard let last = item.lastEvidenceAt else { return true }
    let boundary = TasteStatementDisplay.staleAfterHalfLives * item.claim.evidenceClass.halfLifeDays
    return now.timeIntervalSince(last) > boundary * 86_400
  }

  /// Sentence text. English copy; the app renders localized copy from `templateId`
  /// when a catalogue exists — the plain sentence is what the contract's `text` field
  /// pins and what the golden fixture shows.
  static func render(
    claim: TasteInferredClaim, name: String, numerator: Int, denominator: Int, hedged: Bool
  ) -> String {
    switch (claim, hedged) {
    case (.lowRating, true):
      return
        "You seem to go off \(name): the last \(numerator) recipes you cooked with it were rated 2 stars or below."
    case (.lowRating, false):
      return
        "You go off \(name): \(numerator) of the \(denominator) recipes you cooked with it were rated 2 stars or below."
    case (.substitutedAway, true):
      return
        "You seem to avoid \(name): you swapped it out the last \(numerator) times you cooked with it."
    case (.substitutedAway, false):
      return
        "You avoid \(name): you swapped it out in \(numerator) of the \(denominator) recipes you cooked with it."
    }
  }
}
