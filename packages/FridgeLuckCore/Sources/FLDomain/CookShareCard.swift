import Foundation

// MARK: - Cook sharing
// SPEC 3.4: sharing is a separate action with a preview of exactly what
// leaves the phone. These types ARE that preview: the shareable form of a
// cook carries the day — never exact start or finish times — and never
// pantry, health or taste data, which are not even representable here. The
// coded key set is frozen by a contract test (Review round 1, item 6).

/// One swap as shareable fact: canonical names and the recorded necessity.
/// Line IDs, quantities and household-local ingredient references do not
/// travel.
public struct CookShareSwap: Hashable, Codable, Sendable {
    public let fromName: String
    public let toName: String
    public let necessity: CookSubstitution.Necessity

    public init(fromName: String, toName: String, necessity: CookSubstitution.Necessity) throws {
        let trimmedFrom = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = toName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty, !trimmedTo.isEmpty else {
            throw FLDomainError.validation(target: "CookShareSwap", reason: "swap names must not be empty")
        }
        self.fromName = trimmedFrom
        self.toName = trimmedTo
        self.necessity = necessity
    }

    /// Projects a recorded substitution onto the shareable fact.
    public init(substitution: CookSubstitution) throws {
        try self.init(
            fromName: substitution.from.canonicalName,
            toName: substitution.to.canonicalName,
            necessity: substitution.necessity
        )
    }
}

/// The shareable form of one cook: the recipe revision, the UTC calendar day
/// it happened, servings, swaps, rating and an optional one-line note.
///
/// Redaction is structural (SPEC 3.4): exact times, the household-local cook
/// ID and any pantry, health or taste linkage are not fields and cannot be
/// attached. Build from a `Cook` for sharing; build directly for a received
/// share. The same servings, rating and note rules as `Cook` carry over.
public struct CookShareCard: Hashable, Codable, Sendable {
    public let recipeRevision: RecipeKey
    /// UTC calendar day of the cook, "YYYY-MM-DD" — no time of day.
    public let day: String
    public let servings: Int
    public let swaps: [CookShareSwap]
    /// 1...5.
    public let rating: Int
    public let note: String?

    /// Builds the card from a cook, deriving the day in UTC. Nothing but the
    /// fields below is read — that is the whole redaction story.
    public init(cook: Cook) throws {
        try self.init(
            recipeRevision: cook.recipeRevision,
            servings: cook.servings,
            swaps: try cook.substitutions.map(CookShareSwap.init(substitution:)),
            rating: cook.rating,
            note: cook.note,
            day: Self.dayString(from: cook.completedAt)
        )
    }

    public init(
        recipeRevision: RecipeKey,
        servings: Int,
        swaps: [CookShareSwap] = [],
        rating: Int,
        note: String? = nil,
        day: String
    ) throws {
        guard servings >= 1 else {
            throw FLDomainError.validation(target: "CookShareCard.servings", reason: "must be >= 1 (got \(servings))")
        }
        guard (1...5).contains(rating) else {
            throw FLDomainError.validation(target: "CookShareCard.rating", reason: "must be in 1...5 (got \(rating))")
        }
        if let note {
            guard !note.contains("\n") else {
                throw FLDomainError.validation(target: "CookShareCard.note", reason: "note is one line; newlines are not allowed")
            }
        }
        guard Self.isValidDay(day) else {
            throw FLDomainError.validation(target: "CookShareCard.day", reason: "must be a UTC calendar day \"YYYY-MM-DD\" (got \(day))")
        }
        self.recipeRevision = recipeRevision
        self.day = day
        self.servings = servings
        self.swaps = swaps
        self.rating = rating
        self.note = note
    }

    /// The one day rule: exactly four digits, dash, two digits, dash, two
    /// digits — a plain "YYYY-MM-DD", never a timestamp.
    private static func isValidDay(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10 else { return false }
        let isDigit = { (byte: UInt8) in byte >= 0x30 && byte <= 0x39 }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 4, 7: guard byte == 0x2D else { return false } // '-'
            default: guard isDigit(byte) else { return false }
            }
        }
        return true
    }

    /// The day component of a cook timestamp in UTC — the shared form knows
    /// when a cook happened to the day, never to the minute.
    private static func dayString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
