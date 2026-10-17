import Foundation

// MARK: - The finished-cook record
// SPEC 3.4: finishing a cook saves it locally; sharing is a separate action with
// a preview of exactly what leaves the phone. What a shared cook contains:
// recipe revision, servings, swaps, rating, an optional one-line note. Never
// pantry, health profile, taste data or exact time beyond the day. This type is
// the shape community sharing will publish — no pantry or health data is even
// representable in it, and a contract test freezes its coded key set.

/// A substitution recorded on a cook. SPEC 3.3: a swap records whether it was
/// necessary (didn't have it) or preferred, when the user says so. SPEC 3.1:
/// every substitution rechecks all eaters' allergens — that recheck lives in
/// the substitution engine; the record carries what was swapped and why.
public struct CookSubstitution: Hashable, Sendable {
    public enum Necessity: String, Codable, Sendable {
        /// The pantry forced the swap.
        case necessary
        /// The user preferred the swap.
        case preferred
    }

    public let from: IngredientReference
    public let to: IngredientReference
    public let necessity: Necessity

    public init(from: IngredientReference, to: IngredientReference, necessity: Necessity) throws {
        guard from != to else {
            throw FLDomainError.validation(target: "CookSubstitution", reason: "from and to must differ (substituting '\(from.canonicalName)' with itself)")
        }
        self.from = from
        self.to = to
        self.necessity = necessity
    }
}

/// One finished cook.
public struct Cook: Hashable, Sendable {
    /// Stable cook identity (a UUID string is typical). Never empty.
    public let id: String
    public let recipeRevision: RecipeKey
    /// Servings actually cooked. At least 1.
    public let servings: Int
    public let substitutions: [CookSubstitution]
    /// 1...5.
    public let rating: Int
    /// Optional one-line note. Newlines are rejected: the note is one line.
    public let note: String?
    public let startedAt: Date?
    public let completedAt: Date

    public init(
        id: String,
        recipeRevision: RecipeKey,
        servings: Int,
        substitutions: [CookSubstitution] = [],
        rating: Int,
        note: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date
    ) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "Cook.id", reason: "must not be empty")
        }
        guard servings >= 1 else {
            throw FLDomainError.validation(target: "Cook.servings", reason: "must be >= 1 (got \(servings))")
        }
        guard (1...5).contains(rating) else {
            throw FLDomainError.validation(target: "Cook.rating", reason: "must be in 1...5 (got \(rating))")
        }
        if let note {
            guard !note.contains("\n") else {
                throw FLDomainError.validation(target: "Cook.note", reason: "note is one line; newlines are not allowed")
            }
        }
        if let startedAt {
            guard completedAt >= startedAt else {
                throw FLDomainError.validation(target: "Cook.completedAt", reason: "completedAt must be at or after startedAt")
            }
        }
        self.id = trimmedID
        self.recipeRevision = recipeRevision
        self.servings = servings
        self.substitutions = substitutions
        self.rating = rating
        self.note = note
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

extension Cook: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, recipeRevision, servings, substitutions, rating, note
        case startedAt, completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            recipeRevision: try container.decode(RecipeKey.self, forKey: .recipeRevision),
            servings: try container.decode(Int.self, forKey: .servings),
            substitutions: try container.decodeIfPresent([CookSubstitution].self, forKey: .substitutions) ?? [],
            rating: try container.decode(Int.self, forKey: .rating),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            startedAt: {
                guard let raw = try container.decodeIfPresent(String.self, forKey: .startedAt) else { return nil }
                return try FLTimestamp.decode(raw, target: "Cook.startedAt")
            }(),
            completedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .completedAt),
                target: "Cook.completedAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recipeRevision, forKey: .recipeRevision)
        try container.encode(servings, forKey: .servings)
        try container.encode(substitutions, forKey: .substitutions)
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(startedAt.map(FLTimestamp.encode), forKey: .startedAt)
        try container.encode(FLTimestamp.encode(completedAt), forKey: .completedAt)
    }
}

extension CookSubstitution: Codable {
    private enum CodingKeys: String, CodingKey { case from, to, necessity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            from: try container.decode(IngredientReference.self, forKey: .from),
            to: try container.decode(IngredientReference.self, forKey: .to),
            necessity: try container.decode(Necessity.self, forKey: .necessity)
        )
    }
}
