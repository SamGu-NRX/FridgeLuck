// Public model types for FLIngredientFacts.
//
// Semantics contract: packages/FLIngredientFacts/README.md (pinned for this branch).
// Wheat (an FDA allergen) and gluten (a separate property) are independent axes:
// evidence for one never establishes absence for the other.

/// The nine FDA FALCPA major food allergens.
public enum FLAllergen: String, Codable, Sendable, CaseIterable, Hashable {
    case milk
    case egg
    case fish
    case crustaceanShellfish
    case treeNuts
    case peanuts
    case wheat
    case soy
    case sesame
}

/// Dietary restrictions tracked by FridgeLuck.
public enum FLDiet: String, Codable, Sendable, CaseIterable, Hashable {
    case vegetarian
    case vegan
    case pescatarian
    case glutenFree
    case dairyFree
}

/// One avoided allergen or diet. A meal's restrictions are the union of every
/// eater's restrictions.
public enum FLRestriction: Codable, Hashable, Sendable {
    case allergen(FLAllergen)
    case diet(FLDiet)
}

/// The set of restrictions a recipe is evaluated against.
public struct FLRestrictions: Codable, Hashable, Sendable {
    public var allergens: Set<FLAllergen>
    public var diets: Set<FLDiet>

    public init(allergens: Set<FLAllergen> = [], diets: Set<FLDiet> = []) {
        self.allergens = allergens
        self.diets = diets
    }

    public static let empty = FLRestrictions()

    /// Meal restrictions are the union of every eater's restrictions.
    public static func union(_ sets: [FLRestrictions]) -> FLRestrictions {
        var result = FLRestrictions()
        for set in sets {
            result.allergens.formUnion(set.allergens)
            result.diets.formUnion(set.diets)
        }
        return result
    }

    /// Deterministic iteration order for evaluation and reporting.
    var orderedRestrictions: [FLRestriction] {
        FLAllergen.allCases.filter { allergens.contains($0) }.map(FLRestriction.allergen)
            + FLDiet.allCases.filter { diets.contains($0) }.map(FLRestriction.diet)
    }
}

/// Sourced support for a fact. `usda` refs are FDC ids, `label` refs name the
/// product claim, `reference` refs are URLs or document titles, `recipe` refs
/// are corpus paths, `standard` refs name the composition or regulatory claim.
public struct FLEvidence: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case usda
        case label
        case reference
        case recipe
        case standard
    }

    public var kind: Kind
    public var ref: String
    public var note: String

    public init(kind: Kind, ref: String, note: String) {
        self.kind = kind
        self.ref = ref
        self.note = note
    }
}

/// Why an ingredient is not allowed for a restriction.
public struct FLViolation: Codable, Hashable, Sendable {
    public var ingredient: String
    public var restriction: FLRestriction
    public var reason: String
    public var evidence: [FLEvidence]

    public init(ingredient: String, restriction: FLRestriction, reason: String, evidence: [FLEvidence]) {
        self.ingredient = ingredient
        self.restriction = restriction
        self.reason = reason
        self.evidence = evidence
    }
}

/// Why evaluation could not decide: what is missing, per restriction.
public struct FLUnknown: Codable, Hashable, Sendable {
    public var ingredient: String
    public var restriction: FLRestriction
    public var missing: [String]
    public var reason: String

    public init(ingredient: String, restriction: FLRestriction, missing: [String], reason: String) {
        self.ingredient = ingredient
        self.restriction = restriction
        self.missing = missing
        self.reason = reason
    }
}

/// The outcome of evaluating one ingredient against restrictions.
/// `violated` beats `unknown` beats `allowed`.
public enum FLEvaluation: Codable, Hashable, Sendable {
    case allowed([FLEvidence])
    case violated(FLViolation)
    case unknown(FLUnknown)
}

/// A resolved ingredient identity: canonical key plus catalog and app mappings.
public struct FLIngredientIdentity: Codable, Hashable, Sendable {
    public var key: String
    public var displayName: String
    public var synonyms: [String]
    public var usdaFdcId: Int?
    public var usdaRef: String?
    public var usdaNote: String?
    public var appLocalIds: [Int]

    public init(
        key: String,
        displayName: String,
        synonyms: [String] = [],
        usdaFdcId: Int? = nil,
        usdaRef: String? = nil,
        usdaNote: String? = nil,
        appLocalIds: [Int] = []
    ) {
        self.key = key
        self.displayName = displayName
        self.synonyms = synonyms
        self.usdaFdcId = usdaFdcId
        self.usdaRef = usdaRef
        self.usdaNote = usdaNote
        self.appLocalIds = appLocalIds
    }
}
