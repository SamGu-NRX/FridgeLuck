import Foundation
import FLDomain

// MARK: - The shared-cook payload
// SPEC 3.4: finishing a cook saves it locally; sharing is a separate action
// with a preview of exactly what leaves the phone. What a shared cook may
// contain: recipe revision, servings, swaps, rating, an optional one-line
// note. NEVER pantry, health profile, taste data or exact time beyond the
// day. This type is that redaction boundary: it is constructible from a Cook
// plus the revision, and its encoded key set is frozen by contract test —
// there is no field here that could carry pantry, health or taste data, and
// the completion time is a calendar day, nothing more.

/// A swap in the shareable shape.
///
/// `CookSubstitution` is Codable in FLDomain, but the share wire shape keeps
/// its own explicit, frozen bridge: identical fields, validated at decode,
/// independent of FLDomain's encoding choices. If Part 1 later freezes the
/// same shape there, this type can retire in a contract change.
public struct SharedCookSwap: Hashable, Sendable {
    public let from: IngredientReference
    public let to: IngredientReference
    public let necessity: CookSubstitution.Necessity

    public init(from: IngredientReference, to: IngredientReference, necessity: CookSubstitution.Necessity) {
        self.from = from
        self.to = to
        self.necessity = necessity
    }

    public init(_ substitution: CookSubstitution) {
        self.from = substitution.from
        self.to = substitution.to
        self.necessity = substitution.necessity
    }

    /// Back to the domain value; validates from != to at the boundary.
    public var asSubstitution: CookSubstitution? {
        try? CookSubstitution(from: from, to: to, necessity: necessity)
    }
}

extension SharedCookSwap: Codable {
    private enum CodingKeys: String, CodingKey { case from, to, necessity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            from: try container.decode(IngredientReference.self, forKey: .from),
            to: try container.decode(IngredientReference.self, forKey: .to),
            necessity: try container.decode(CookSubstitution.Necessity.self, forKey: .necessity)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(necessity, forKey: .necessity)
    }
}

/// A finished cook in exactly the shape that may be shared.
public struct SharedCook: Hashable, Sendable {
    /// The frozen top-level field names of the wire shape (sorted, matching
    /// the canonical encoder). The contract test asserts the encoder emits
    /// exactly these keys and no others.
    public static let sharedFieldNames: [String] = [
        "completedOn", "note", "rating", "recipeRevision", "servings", "swaps",
    ]

    /// The full revision, so the recipient can cook it. Its license evidence
    /// travels inside it, unchanged.
    public let recipeRevision: RecipeRevision
    /// Servings actually cooked. At least 1.
    public let servings: Int
    /// Swaps made, with their recorded necessity. Omitted when empty.
    public let swaps: [SharedCookSwap]
    /// 1...5.
    public let rating: Int
    /// Optional one-line note. Omitted when absent.
    public let note: String?
    /// The calendar day the cook completed, "yyyy-MM-dd" in the household's
    /// own time zone. Never an instant: exact time beyond the day must not
    /// leave the phone (SPEC 3.4).
    public let completedOn: String

    /// Build the shareable shape from a finished cook.
    ///
    /// Constructing one is an export: the revision text embeds here, so the
    /// `RecipeExportGate` runs first — a forbidden or quarantined revision
    /// (LeChef draft, forbidden text/offline rights, unknown rights,
    /// non-permitted caching, required attribution missing) is refused, the
    /// same policy as recipe sharing (SPEC 3.5).
    ///
    /// - Parameters:
    ///   - cook: the finished cook. Only its shareable fields are read; its
    ///     `startedAt` instant and any local identifiers stay behind.
    ///   - revision: the revision that was cooked. Its key must match the
    ///     cook's record — a shared cook claims to be a cook OF something.
    ///   - completedOn: the calendar day, "yyyy-MM-dd", computed by the host
    ///     in the household's time zone (this library never guesses a zone).
    public init(cook: Cook, revision: RecipeRevision, completedOn: String) throws {
        // Export gate first: rights are judged before anything else about
        // the payload — the cook's own fields never rehabilitate a revision
        // that may not leave the phone.
        try RecipeExportGate.validateExportable(revision, target: "SharedCook.recipeRevision")
        guard cook.recipeRevision == revision.key else {
            throw FLDomainError.validation(
                target: "SharedCook.recipeRevision",
                reason: "cook records \(cook.recipeRevision), but the supplied revision is \(revision.key)"
            )
        }
        let trimmedDay = completedOn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDay(trimmedDay) else {
            throw FLDomainError.validation(
                target: "SharedCook.completedOn",
                reason: "must be a real calendar day formatted yyyy-MM-dd (got \(completedOn))"
            )
        }
        self.recipeRevision = revision
        self.servings = cook.servings
        self.swaps = cook.substitutions.map(SharedCookSwap.init)
        self.rating = cook.rating
        self.note = cook.note
        self.completedOn = trimmedDay
    }

    /// Builds the shareable shape without the export policy. Internal (not
    /// private) so tests can hand-build cooks a non-policy sender's app
    /// might produce — the same assumption the recipe-payload tests make.
    /// The boundary still refuses such a payload: decode and encode both
    /// run the gate, so unvalidated text cannot enter or leave.
    init(checkedCook cook: Cook, uncheckedRevision revision: RecipeRevision, completedOn: String) {
        self.recipeRevision = revision
        self.servings = cook.servings
        self.swaps = cook.substitutions.map(SharedCookSwap.init)
        self.rating = cook.rating
        self.note = cook.note
        self.completedOn = completedOn
    }

    /// Strict "yyyy-MM-dd" validation: four-digit year 2000...2100, real
    /// month, real day for that month (leap years included). Deliberately
    /// manual — a date formatter forward-rolls "2026-02-30" into March,
    /// which would turn a typo into a silent lie.
    public static func isValidDay(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...2100).contains(year),
              (1...12).contains(month)
        else { return false }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...daysInMonth).contains(day)
    }

    /// The calendar-day string for an instant in a named time zone. The host
    /// calls this with the household's zone; the payload itself carries no
    /// zone, because the zone would leak where the household lives.
    public static func dayString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

extension SharedCook: Codable {
    private enum CodingKeys: String, CodingKey {
        case recipeRevision, servings, swaps, rating, note, completedOn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let servings = try container.decode(Int.self, forKey: .servings)
        guard servings >= 1 else {
            throw FLDomainError.validation(target: "SharedCook.servings", reason: "must be >= 1 (got \(servings))")
        }
        let rating = try container.decode(Int.self, forKey: .rating)
        guard (1...5).contains(rating) else {
            throw FLDomainError.validation(target: "SharedCook.rating", reason: "must be in 1...5 (got \(rating))")
        }
        if let note = try container.decodeIfPresent(String.self, forKey: .note) {
            guard !note.contains("\n") else {
                throw FLDomainError.validation(target: "SharedCook.note", reason: "note is one line; newlines are not allowed")
            }
            self.note = note
        } else {
            self.note = nil
        }
        self.recipeRevision = try container.decode(RecipeRevision.self, forKey: .recipeRevision)
        // Inbound gate (review round 2): every revision entering the phone
        // passes the same policy as construction and encoding. A shared cook
        // embeds full text, so a forbidden or quarantined revision must not
        // arrive via decode either — the check fails closed on missing or
        // unknown rights.
        try RecipeExportGate.validateExportable(self.recipeRevision, target: "SharedCook.recipeRevision")
        self.servings = servings
        self.swaps = try container.decodeIfPresent([SharedCookSwap].self, forKey: .swaps) ?? []
        self.rating = rating
        let day = try container.decode(String.self, forKey: .completedOn)
        guard Self.isValidDay(day) else {
            throw FLDomainError.validation(
                target: "SharedCook.completedOn",
                reason: "must be a real calendar day formatted yyyy-MM-dd (got \(day))"
            )
        }
        self.completedOn = day
    }

    public func encode(to encoder: Encoder) throws {
        // Outgoing boundary (review round 2): encoding revalidates the
        // embedded revision — no payload leaves the phone unchecked, even
        // one assembled by a path that skipped the checked constructor.
        try RecipeExportGate.validateExportable(recipeRevision, target: "SharedCook.recipeRevision")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recipeRevision, forKey: .recipeRevision)
        try container.encode(servings, forKey: .servings)
        if !swaps.isEmpty {
            try container.encode(swaps, forKey: .swaps)
        }
        try container.encode(rating, forKey: .rating)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(completedOn, forKey: .completedOn)
    }
}
