import Foundation

/// Stable identifier for an event in the append-only log.
///
/// Ingest is idempotent by this id: replaying an event whose id was already
/// folded is a no-op.
public struct EventID: Hashable, Comparable, Sendable {
    public let rawValue: String

    /// Fails on an empty or whitespace-only string; callers decide at the
    /// boundary what to do with invalid input.
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public static func < (lhs: EventID, rhs: EventID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies one eater inside a household. A household with a single eater
/// still names that eater, so one- and two-eater households use one code path.
/// Comparable (by rawValue) so fold order over eaters is deterministic.
public struct EaterID: Hashable, Comparable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public static func < (lhs: EaterID, rhs: EaterID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies a recipe. The app catalog uses integer ids; FLTaste takes the
/// string form so the research package stays independent of the app models.
public struct RecipeID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }
}

/// Identifies an ingredient in the catalog (the 50 core ingredients).
public struct IngredientID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }
}
