import FLIngredientFacts

import Foundation

/// Per-100 g nutrient values (USDA SR Legacy fields).
public struct Macros: Codable, Sendable, Equatable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double
    public var sugarG: Double
    public var sodiumMg: Double

    enum CodingKeys: String, CodingKey {
        case kcal
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case sodiumMg = "sodium_mg"
    }
}

/// One ingredient identity. `classes` are compound-expanded: what the
/// ingredient IS (soy sauce = soy + gluten), not just what its name says.
public struct IngredientRecord: Codable, Sendable {
    public let display: String
    public let fdcID: Int?
    public let usdaName: String?
    public let macrosPer100g: Macros?
    public let classes: [AllergenClass]
    public let allergenNote: String?
    public let aliases: [String]
    /// The canonical FLIngredientFacts identity this record maps to (PR #114
    /// fix list §3.2). Nil means no confidently matched fact record exists —
    /// the recheck then tries the display name and otherwise fails closed
    /// (ask the user). Never fuzzy-matched at runtime; the mapping is
    /// reviewed data.
    public let factsKey: String?

    enum CodingKeys: String, CodingKey {
        case display
        case fdcID = "fdc_id"
        case usdaName = "usda_name"
        case macrosPer100g = "macros_per_100g"
        case classes
        case allergenNote = "allergen_note"
        case aliases
        case factsKey = "facts_key"
    }
}

/// How much substitute to use for the original. `value` is numeric in the
/// unit named by `basis` (for example `weight` means grams substitute per
/// gram original; `quarter-cup-per-egg` means quarter cups per egg).
public struct Ratio: Codable, Sendable {
    public let value: Double
    public let basis: String
    public let status: EvidenceStatus
    /// Where a conflicting shipped or prior claim disagrees, verbatim.
    public let conflictWith: String?
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case value
        case basis
        case status
        case conflictWith = "conflict_with"
        case note
    }
}

/// A second role the swap can serve, with that role's own ratio evidence.
/// `ratio` records THAT role's actual ratio when it has been evidenced;
/// scaling is never offered from the primary ratio for an alternative role
/// (review finding f). Absent `ratio` means scaling is unavailable for the
/// role until the amount is sourced and stored.
public struct SupportedAlso: Codable, Sendable {
    public let role: Role
    public let status: EvidenceStatus
    public let ratio: Ratio?
}

/// Why a recorded failure fails: outright, or only for the named eaters.
///
/// - `functional`: the substitute cannot perform the role at all (a flax gel
///   does not aerate). A sourced ratio can never override this — evidence for
///   an amount does not create the function (review finding e).
/// - `conditional`: the swap works in general but is refused for the named
///   restrictions (seitan works as protein but is refused for gluten-free
///   eaters). The refusal is enforced at the recheck layer, separately from
///   the context verdict.
public enum FailsKind: String, Codable, Sendable {
    case functional
    case conditional
}

/// A role where the swap FAILS, and why (for example a flax egg fails as a
/// baking leavening; applesauce fails as a creaming fat).
public struct FailsRole: Codable, Sendable {
    public let role: Role
    public let why: String
    public let kind: FailsKind
    /// For `conditional` rows: the restriction names that trigger the refusal.
    public let restrictions: [String]?
}

/// One reviewed substitution pair. Every field is evidence-honest:
/// unknown stays unknown (SPEC §3.5).
public struct Pair: Codable, Sendable {
    public let id: String
    public let original: String
    public let substitute: String
    public let role: Role
    public let ratio: Ratio
    public let functionStatus: EvidenceStatus
    public let supportedAlso: [SupportedAlso]
    public let fails: [FailsRole]
    public let preparation: [String]
    /// Plain-language flavour and texture difference. Never promises "no change".
    public let difference: String
    /// Typical amount of the ORIGINAL ingredient in grams, when defined.
    public let typicalAmountG: Double?
    /// Macro delta at the typical amounts (see SCHEMA.md for the method).
    public let macroDelta: Macros?
    /// Why the macro delta is null, when it is.
    public let macroDeltaNullReason: String?
    public let sourceIDs: [String]
    public let assessment: String?

    enum CodingKeys: String, CodingKey {
        case id
        case original
        case substitute
        case role
        case ratio
        case functionStatus = "function_status"
        case supportedAlso = "supported_also"
        case fails
        case preparation
        case difference
        case typicalAmountG = "typical_amount_g"
        case macroDelta = "macro_delta"
        case macroDeltaNullReason = "macro_delta_null_reason"
        case sourceIDs = "source_ids"
        case assessment
    }
}

/// One entry of the reviewed source registry (PR #49's registry reused first).
public struct SourceRecord: Codable, Sendable {
    public let id: String
    public let publisher: String
    public let title: String
    public let url: String
    public let retrieved: String
    public let whatItShows: String
    public let reusedFrom: String?

    enum CodingKeys: String, CodingKey {
        case id
        case publisher
        case title
        case url
        case retrieved
        case whatItShows = "what_it_shows"
        case reusedFrom = "reused_from"
    }
}

/// A named restriction: the classes it forbids (the table's label registry,
/// used for evidence labels and diffing) and its mapping into the shared
/// restriction vocabulary (`FLRestrictions`), which is the operative
/// semantics the recheck evaluates (fix list §3.4).
public struct Restriction: Codable, Sendable {
    public let forbids: [AllergenClass]
    /// The shared-vocabulary restriction this name means. Unknown enum
    /// strings are load errors (SubstitutionTable validation).
    public let fl: FLMapping
}

/// The per-restriction bridge into FLIngredientFacts' vocabulary: which
/// FLAllergen/FLDiet axes the restriction name stands for.
///
/// Codable is explicit over raw strings rather than synthesized over the
/// FLIngredientFacts enums: unknown axis strings are LOADING ERRORS (thrown
/// as DecodingError), and the JSON shape stays plain strings.
public struct FLMapping: Codable, Sendable {
    public let allergens: [FLAllergen]
    public let diets: [FLDiet]

    public init(allergens: [FLAllergen], diets: [FLDiet]) {
        self.allergens = allergens
        self.diets = diets
    }

    private enum CodingKeys: String, CodingKey {
        case allergens
        case diets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawAllergens = try container.decode([String].self, forKey: .allergens)
        var allergens: [FLAllergen] = []
        for raw in rawAllergens {
            guard let axis = FLAllergen(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .allergens, in: container, debugDescription: "unknown FLAllergen '\(raw)'"
                )
            }
            allergens.append(axis)
        }

        let rawDiets = try container.decode([String].self, forKey: .diets)
        var diets: [FLDiet] = []
        for raw in rawDiets {
            guard let axis = FLDiet(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .diets, in: container, debugDescription: "unknown FLDiet '\(raw)'"
                )
            }
            diets.append(axis)
        }

        self.allergens = allergens
        self.diets = diets
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allergens.map(\.rawValue), forKey: .allergens)
        try container.encode(diets.map(\.rawValue), forKey: .diets)
    }
}
