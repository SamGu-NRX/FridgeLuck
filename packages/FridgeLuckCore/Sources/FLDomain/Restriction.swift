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
    /// not cover. Never empty strings.
    public var customExclusions: Set<String>

    public init(
        allergens: Set<Allergen> = [],
        dietExclusions: Set<DietExclusion> = [],
        customExclusions: Set<String> = []
    ) throws {
        for name in customExclusions {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "Restriction.customExclusions", reason: "custom exclusion names must not be empty")
            }
        }
        self.allergens = allergens
        self.dietExclusions = dietExclusions
        self.customExclusions = customExclusions
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
    ///     exclusion matches exactly.
    ///   - allergens: allergens declared for it, including compound ingredients
    ///     (soy sauce contains wheat, pesto contains nuts) — the caller
    ///     resolves compound ingredients to their declared allergen set.
    ///   - dietTags: diet tags it fails to satisfy.
    public func permits(
        canonicalName: String,
        allergens: Set<Allergen> = [],
        dietTags: Set<DietExclusion> = []
    ) -> Bool {
        if customExclusions.contains(canonicalName) { return false }
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
