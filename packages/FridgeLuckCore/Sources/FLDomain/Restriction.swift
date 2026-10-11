import Foundation

// MARK: - Hard restrictions
// SPEC 3.3: three separate layers — explicit restrictions (allergies, diets;
// hard filters, never weakened, survive any reset), stated preferences, and
// inferred taste. This type is the first layer. Inferred taste lives elsewhere
// and can never weaken what this type forbids.

/// A named allergen. Raw values are part of the cross-language fixture contract.
public enum Allergen: String, Codable, Sendable, CaseIterable {
    case peanuts
    case treeNuts
    case milk
    case eggs
    case wheat
    case gluten
    case soy
    case fish
    case shellfish
    case sesame
}

/// A named diet exclusion. Raw values are part of the cross-language fixture contract.
public enum DietExclusion: String, Codable, Sendable, CaseIterable {
    case vegetarian
    case vegan
    case pescatarian
    case halal
    case kosher
    case lowSodium
    case noPork
    case noAlcohol
    case lactoseFree
}

/// The hard constraints of one person: allergen and diet exclusions plus any
/// custom exclusion they named. These are hard filters — ranking, swaps,
/// substitutes and LeChef proposals must all respect them, and a preference
/// reset never clears them (they are not taste).
public struct Restriction: Hashable, Sendable {
    public var allergens: Set<Allergen>
    public var dietExclusions: Set<DietExclusion>
    /// Canonical ingredient names the person excludes that the fixed enums do
    /// not cover. Stored normalized (Review round 1, item 3): trimmed and
    /// case-folded, never empty — the stored form IS the matching form. The
    /// storage is read-only; extend through `addingCustomExclusion(_:)`,
    /// which applies the same validation as construction.
    public private(set) var customExclusions: Set<String>

    /// The one normalization rule for custom exclusions: trim surrounding
    /// whitespace, case-fold. Construction, mutation and matching all share
    /// it, so storage and matching can never drift apart.
    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(
        allergens: Set<Allergen> = [],
        dietExclusions: Set<DietExclusion> = [],
        customExclusions: Set<String> = []
    ) throws {
        var normalizedExclusions: Set<String> = []
        for name in customExclusions {
            let trimmed = Self.normalized(name)
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "Restriction.customExclusions", reason: "custom exclusion names must not be empty")
            }
            normalizedExclusions.insert(trimmed)
        }
        self.allergens = allergens
        self.dietExclusions = dietExclusions
        self.customExclusions = normalizedExclusions
    }

    /// Adds one custom exclusion through the same validation as construction.
    public mutating func addingCustomExclusion(_ name: String) throws {
        self = try Restriction(
            allergens: allergens,
            dietExclusions: dietExclusions,
            customExclusions: customExclusions.union([name])
        )
    }

    public var isEmpty: Bool {
        allergens.isEmpty && dietExclusions.isEmpty && customExclusions.isEmpty
    }

    /// The union of all eaters' restrictions applies to a meal (SPEC 2: hard
    /// restrictions are the union of all eaters').
    public func union(_ other: Restriction) -> Restriction {
        var merged = self
        merged.allergens = merged.allergens.union(other.allergens)
        merged.dietExclusions = merged.dietExclusions.union(other.dietExclusions)
        merged.customExclusions = merged.customExclusions.union(other.customExclusions)
        return merged
    }

    /// The hard-filter question: may this person eat something with these
    /// declared properties?
    ///
    /// - Parameters:
    ///   - canonicalName: the ingredient or dish's canonical name; a custom
    ///     exclusion matches after the same normalization exclusions receive
    ///     at construction (trim + case-fold), so padded or differently-cased
    ///     queries still block.
    ///   - allergens: allergens declared for it, including compound ingredients
    ///     (soy sauce contains wheat, pesto contains nuts) — the caller
    ///     resolves compound ingredients to their declared allergen set.
    ///   - dietTags: diet tags it fails to satisfy.
    public func permits(
        canonicalName: String,
        allergens: Set<Allergen> = [],
        dietTags: Set<DietExclusion> = []
    ) -> Bool {
        if customExclusions.contains(Self.normalized(canonicalName)) { return false }
        if !allergens.isDisjoint(with: self.allergens) { return false }
        if !dietTags.isDisjoint(with: dietExclusions) { return false }
        return true
    }
}

extension Restriction: Codable {
    private enum CodingKeys: String, CodingKey {
        case allergens, dietExclusions, customExclusions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            allergens: try container.decodeIfPresent(Set<Allergen>.self, forKey: .allergens) ?? [],
            dietExclusions: try container.decodeIfPresent(Set<DietExclusion>.self, forKey: .dietExclusions) ?? [],
            customExclusions: try container.decodeIfPresent(Set<String>.self, forKey: .customExclusions) ?? []
        )
    }
}
