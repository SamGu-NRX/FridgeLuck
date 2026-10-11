import Foundation

public enum SubstitutionError: Error, Equatable {
    case unknownIngredient(String)
    case unknownRestriction(String)
    case defaultTableNotFound
}

/// The union of restrictions carried by the eaters at the table.
/// Unknown restriction names throw — never silently dropped.
public struct RestrictionSet: Sendable {
    public let names: [String]
    public let forbidden: Set<AllergenClass>

    public init(names: [String], table: SubstitutionTable) throws {
        var resolved: [String] = []
        var forbidden: Set<AllergenClass> = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let restriction = table.restrictions[name] else {
                throw SubstitutionError.unknownRestriction(raw)
            }
            guard !resolved.contains(name) else { continue }
            resolved.append(name)
            forbidden.formUnion(restriction.forbids)
        }
        self.names = resolved.sorted()
        self.forbidden = forbidden
    }
}

/// The allergen-recheck result for one proposed swap: what each side carries,
/// what the swap would introduce or remove, and what (if anything) violates
/// the eaters' restrictions. Class lists are sorted for deterministic output.
public struct AllergenRecheck: Sendable, Equatable {
    public let originalClasses: [AllergenClass]
    public let substituteClasses: [AllergenClass]
    /// Classes the substitute adds that the original did not have.
    public let introduced: [AllergenClass]
    /// Classes the original had that the substitute drops.
    public let removed: [AllergenClass]
    /// Substitute classes that violate the eaters' restrictions. A swap with
    /// any violation is refused — the substitute must be safe in itself,
    /// regardless of what the original carried.
    public let violated: [AllergenClass]

    public var isRefused: Bool { !violated.isEmpty }
}

func sortedClasses(_ classes: [AllergenClass]) -> [AllergenClass] {
    classes.sorted { $0.rawValue < $1.rawValue }
}
