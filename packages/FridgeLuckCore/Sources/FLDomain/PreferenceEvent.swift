import Foundation

// MARK: - Preference events
// SPEC 3.3 + engineering plan Goal 2: every event has a stable ID, a kind, a
// timestamp, the recipe revision it concerns, an optional exposure ID and an
// explicit source. Corrections and retractions reference the prior event rather
// than silently creating another reward. A dismissal or silence is never a
// negative taste label, so it is not representable as an event.

/// Stable event identity. Nonempty, at most 128 characters.
public struct PreferenceEventID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "PreferenceEventID", reason: "must not be empty")
        }
        guard trimmed.count <= 128 else {
            throw FLDomainError.validation(target: "PreferenceEventID", reason: "must be at most 128 characters")
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

extension PreferenceEventID: Codable {
    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(try container.decode(String.self, forKey: .rawValue))
    }
}

/// Where an event came from. Explicit on every event: availability is not
/// preference (SPEC 3.3), so the engine must be able to tell a deliberate user
/// action from app-observed behaviour and from imported history.
public enum PreferenceEventSource: String, Codable, Sendable, CaseIterable {
    /// The user did this deliberately in the UI.
    case userExplicit
    /// The app recorded this from behaviour (a cook completing, a save).
    case appObserved
    /// Imported from historical data, labelled as imported, never invented.
    case imported
}

/// The correction/retraction reference: an event that supersedes a prior event
/// always names it and says how.
public struct EventCorrection: Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The prior event's payload was wrong; this event carries the truth.
        case corrects
        /// The prior event should never have existed.
        case retracts
    }

    public let priorEventID: PreferenceEventID
    public let mode: Mode

    public init(priorEventID: PreferenceEventID, mode: Mode) {
        self.priorEventID = priorEventID
        self.mode = mode
    }
}

/// The verdict on a taste-profile sentence (SPEC 3.3: a page of sentences with
/// evidence, each correctable; "don't ask again" is different from "this is
/// wrong", and changing your mind never requires a full reset).
public enum ProfileSentenceVerdict: String, Codable, Sendable, CaseIterable {
    /// The sentence is right.
    case confirmed
    /// The user corrected the sentence.
    case corrected
    /// The sentence is wrong ("this is wrong" — stronger than a dismissal).
    case rejected
    /// A previously closed sentence was reopened.
    case reopened
}

/// What kind of thing happened. Raw values are part of the cross-language
/// fixture contract; kind-specific fields travel as top-level optional fields
/// (see `encode(to:)`).
public enum PreferenceEventKind: String, Codable, Sendable, CaseIterable {
    /// The recipe was shown to the user (exposure logging: availability is not
    /// preference, so the engine logs what was shown and what was feasible).
    case exposed
    /// The user opened the recipe.
    case opened
    /// The user saved the recipe.
    case saved
    /// The user started cooking.
    case cookStarted
    /// The user finished cooking, with rating, wouldRepeat and optional note.
    case cookCompleted
    /// The user removed an ingredient from a dish they were having or planning.
    case ingredientRemoved
    /// The user substituted one ingredient for another (necessity is recorded
    /// on the cook's substitution record).
    case substituted
    /// An explicit "I don't like this" — outweighs any frequency (SPEC 3.3).
    case explicitDislike
    /// A verdict on a taste-profile sentence.
    case profileEdit
}

/// One recorded preference event. Validated at construction and at decode:
/// kind-specific fields are required exactly when their kind requires them.
public struct PreferenceEvent: Hashable, Sendable {
    public let id: PreferenceEventID
    public let kind: PreferenceEventKind
    public let timestamp: Date
    public let recipeRevision: RecipeKey
    /// The exposure this event belongs to, when the recipe was shown by the app.
    public let exposureID: String?
    /// Explicit source on every event.
    public let source: PreferenceEventSource
    /// Set when this event corrects or retracts a prior event.
    public let supersedes: EventCorrection?
    // Kind-specific payload fields (validated per kind):
    public let rating: Int?
    public let wouldRepeat: Bool?
    public let note: String?
    public let ingredientName: String?
    public let fromIngredient: IngredientReference?
    public let toIngredient: IngredientReference?
    public let sentenceID: String?
    public let verdict: ProfileSentenceVerdict?

    public init(
        id: String,
        kind: PreferenceEventKind,
        timestamp: Date,
        recipeRevision: RecipeKey,
        source: PreferenceEventSource,
        exposureID: String? = nil,
        supersedes: EventCorrection? = nil,
        rating: Int? = nil,
        wouldRepeat: Bool? = nil,
        note: String? = nil,
        ingredientName: String? = nil,
        fromIngredient: IngredientReference? = nil,
        toIngredient: IngredientReference? = nil,
        sentenceID: String? = nil,
        verdict: ProfileSentenceVerdict? = nil
    ) throws {
        let eventID = try PreferenceEventID(id)
        if let exposureID = exposureID.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !exposureID.isEmpty else {
                throw FLDomainError.validation(target: "PreferenceEvent.exposureID", reason: "must not be empty when present")
            }
        }
        if let supersedes {
            guard supersedes.priorEventID != eventID else {
                throw FLDomainError.validation(target: "PreferenceEvent.supersedes", reason: "an event cannot correct or retract itself")
            }
        }

        switch kind {
        case .exposed, .opened, .saved, .cookStarted, .explicitDislike:
            break
        case .cookCompleted:
            guard let cookRating = rating, (1...5).contains(cookRating) else {
                throw FLDomainError.validation(target: "PreferenceEvent.rating", reason: "cookCompleted requires a rating in 1...5 (got \(rating.map(String.init) ?? "nil"))")
            }
            guard wouldRepeat != nil else {
                throw FLDomainError.validation(target: "PreferenceEvent.wouldRepeat", reason: "cookCompleted requires wouldRepeat")
            }
            if let cookNote = note {
                guard !cookNote.contains("\n") else {
                    throw FLDomainError.validation(target: "PreferenceEvent.note", reason: "note is one line; newlines are not allowed")
                }
            }
        case .ingredientRemoved:
            guard let name = ingredientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw FLDomainError.validation(target: "PreferenceEvent.ingredientName", reason: "ingredientRemoved requires the ingredient's canonical name")
            }
        case .substituted:
            guard let from = fromIngredient, let to = toIngredient else {
                throw FLDomainError.validation(target: "PreferenceEvent.substituted", reason: "substituted requires fromIngredient and toIngredient")
            }
            guard from != to else {
                throw FLDomainError.validation(target: "PreferenceEvent.substituted", reason: "substituted from and to must differ")
            }
        case .profileEdit:
            guard let sentence = sentenceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else {
                throw FLDomainError.validation(target: "PreferenceEvent.sentenceID", reason: "profileEdit requires sentenceID")
            }
            guard verdict != nil else {
                throw FLDomainError.validation(target: "PreferenceEvent.verdict", reason: "profileEdit requires a verdict")
            }
        }

        self.id = eventID
        self.kind = kind
        self.timestamp = timestamp
        self.recipeRevision = recipeRevision
        self.exposureID = exposureID
        self.source = source
        self.supersedes = supersedes
        self.rating = rating
        self.wouldRepeat = wouldRepeat
        self.note = note
        self.ingredientName = ingredientName
        self.fromIngredient = fromIngredient
        self.toIngredient = toIngredient
        self.sentenceID = sentenceID
        self.verdict = verdict
    }
}

extension PreferenceEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, recipeRevision, exposureID, source, supersedes
        case rating, wouldRepeat, note, ingredientName
        case fromIngredient, toIngredient
        case sentenceID, verdict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let kind = try container.decode(PreferenceEventKind.self, forKey: .kind)
        let timestamp = try FLTimestamp.decode(
            try container.decode(String.self, forKey: .timestamp),
            target: "PreferenceEvent.timestamp"
        )
        let supersedes = try container.decodeIfPresent(EventCorrection.self, forKey: .supersedes)
        try self.init(
            id: id,
            kind: kind,
            timestamp: timestamp,
            recipeRevision: try container.decode(RecipeKey.self, forKey: .recipeRevision),
            source: try container.decode(PreferenceEventSource.self, forKey: .source),
            exposureID: try container.decodeIfPresent(String.self, forKey: .exposureID),
            supersedes: supersedes,
            rating: try container.decodeIfPresent(Int.self, forKey: .rating),
            wouldRepeat: try container.decodeIfPresent(Bool.self, forKey: .wouldRepeat),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            ingredientName: try container.decodeIfPresent(String.self, forKey: .ingredientName),
            fromIngredient: try container.decodeIfPresent(IngredientReference.self, forKey: .fromIngredient),
            toIngredient: try container.decodeIfPresent(IngredientReference.self, forKey: .toIngredient),
            sentenceID: try container.decodeIfPresent(String.self, forKey: .sentenceID),
            verdict: try container.decodeIfPresent(ProfileSentenceVerdict.self, forKey: .verdict)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(FLTimestamp.encode(timestamp), forKey: .timestamp)
        try container.encode(recipeRevision, forKey: .recipeRevision)
        try container.encodeIfPresent(exposureID, forKey: .exposureID)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(supersedes, forKey: .supersedes)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(wouldRepeat, forKey: .wouldRepeat)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(ingredientName, forKey: .ingredientName)
        try container.encodeIfPresent(fromIngredient, forKey: .fromIngredient)
        try container.encodeIfPresent(toIngredient, forKey: .toIngredient)
        try container.encodeIfPresent(sentenceID, forKey: .sentenceID)
        try container.encodeIfPresent(verdict, forKey: .verdict)
    }
}

extension EventCorrection: Codable {
    private enum CodingKeys: String, CodingKey { case priorEventID, mode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            priorEventID: try PreferenceEventID(try container.decode(String.self, forKey: .priorEventID)),
            mode: try container.decode(Mode.self, forKey: .mode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(priorEventID.rawValue, forKey: .priorEventID)
        try container.encode(mode, forKey: .mode)
    }
}
