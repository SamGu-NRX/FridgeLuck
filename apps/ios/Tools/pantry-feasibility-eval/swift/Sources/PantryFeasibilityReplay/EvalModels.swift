import Foundation

// Corpus types matching the frozen Python harness schema exactly.

struct EvalProfile: Codable {
    var diet: String?
    var allergen_groups: [String]
    var allergen_ingredient_ids: [Int64]
    var allergen_preferences_version: Int
    var goal: String
}

struct EvalLot: Codable {
    var ingredient_id: Int64
    var known_grams: Double?
    var is_estimate: Bool
}

struct EvalState: Codable {
    var state_id: Int
    var family: String
    var profile: EvalProfile
    var pantry: [EvalLot]
    var available_ids: [Int64]

    var availableIDSet: Set<Int64> { Set(available_ids) }
    var pantryIDSet: Set<Int64> { Set(pantry.map(\.ingredient_id)) }
}

struct CatalogRecipe: Codable {
    var recipeID: Int
    var title: String
    var timeMinutes: Int
    var tags: Int
    var requiredRows: [[CodableDouble]]
    var optionalRows: [[CodableDouble]]

    var requiredPairs: [(Int64, Double)] {
        requiredRows.map { ($0[0].int64Value, $0[1].value) }
    }

    var optionalPairs: [(Int64, Double)] {
        optionalRows.map { ($0[0].int64Value, $0[1].value) }
    }
}

/// JSON numbers may arrive as 28 or 28.0; decode both into a Double.
struct CodableDouble: Codable {
    var value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let int = try? container.decode(Int.self) {
            value = Double(int)
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected a number"))
        }
    }

    var int64Value: Int64 { Int64(value) }
}

/// The frozen snapshot stores recipes keyed by recipe ID; decode into
/// full recipes with the key promoted into `recipeID`.
struct CatalogSnapshot: Decodable {
    var recipes: [CatalogRecipe]
    var ingredientNames: [Int64: String]
    var sourceSha256: String

    enum CodingKeys: String, CodingKey {
        case recipes
        case ingredientNames = "ingredient_names"
        case provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyed = try container.decode([String: RawRecipe].self, forKey: .recipes)
        recipes = keyed.map { key, raw in
            CatalogRecipe(
                recipeID: Int(key) ?? -1,
                title: raw.title,
                timeMinutes: raw.time_minutes,
                tags: raw.tags,
                requiredRows: raw.required,
                optionalRows: raw.optional)
        }
        let names = try container.decode([String: String].self, forKey: .ingredientNames)
        ingredientNames = Dictionary(
            uniqueKeysWithValues: names.compactMap { key, value in
                guard let id = Int64(key) else { return nil }
                return (id, value)
            })
        let provenance = try container.decode(RawProvenance.self, forKey: .provenance)
        sourceSha256 = provenance.source_sha256
    }

    struct RawRecipe: Codable {
        var title: String
        var time_minutes: Int
        var tags: Int
        var required: [[CodableDouble]]
        var optional: [[CodableDouble]]
    }

    struct RawProvenance: Codable {
        var source: String
        var source_sha256: String
    }
}

// MARK: - HealthProfile semantics (transcribed)

/// Mirrors the diet/allergen semantics of the production `HealthProfile`
/// (`apps/ios/Domain/Models/HealthProfile.swift`). That file imports GRDB and
/// cannot be vendored into this Foundation-only harness, so the small logic
/// surface the feasibility predicate depends on is transcribed here. A Python
/// sync check compares its outputs against `oracle.py` on the frozen corpus.
struct EvalHealthProfile {
    var diet: String?
    var allergenGroups: [String]
    var allergenIngredientIDs: [Int64]
    var allergenPreferencesVersion: Int

    init(from profile: EvalProfile) {
        // Production lowercases and trims stored restriction strings before
        // mapping them to a canonical diet ID.
        self.diet = profile.diet.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.allergenGroups = profile.allergen_groups
        self.allergenIngredientIDs = profile.allergen_ingredient_ids
        self.allergenPreferencesVersion = profile.allergen_preferences_version
    }

    /// Mirrors `HealthProfile.requiredRecipeTagMask`.
    var requiredRecipeTagMask: Int {
        var tags = 0
        switch diet {
        case "vegan": tags |= 1 << 2        // RecipeTags.vegan
        case "vegetarian": tags |= 1 << 1   // RecipeTags.vegetarian
        case "keto": tags |= 1 << 10        // RecipeTags.lowCarb
        default: break
        }
        return tags
    }

    /// Mirrors `HealthProfile.dietaryExcludedIngredientIds` (vegan drops the
    /// bundled dairy IDs: cheese 12, milk 13, butter 14, yogurt 32, sour cream 50).
    var dietaryExcludedIngredientIds: Set<Int64> {
        diet == "vegan" ? [12, 13, 14, 32, 50] : []
    }

    /// Mirrors `HealthProfile.effectiveAllergenExclusionIds` via the vendored
    /// production `AllergenExclusions` implementation.
    var effectiveAllergenExclusionIds: Set<Int64> {
        AllergenExclusions.effectiveExcludedIngredientIDs(
            selectedGroups: Set(allergenGroups),
            individualExclusions: Set(allergenIngredientIDs)
        )
    }
}
