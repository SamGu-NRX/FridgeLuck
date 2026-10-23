import Foundation

/// A feature in the taste feature space, written `namespace.value`
/// (for example `ingredient.cumin`, `cuisine.mexican`, `time.le30`).
///
/// The string form is the stable, serialized identity of a feature. Feature
/// indices are an implementation detail of the vector and are never
/// serialized.
public struct FeatureKey: Hashable, Comparable, Codable, Sendable {
    public let namespace: String
    public let value: String

    public init(namespace: String, value: String) {
        self.namespace = namespace
        self.value = value
    }

    public init?(key: String) {
        guard let dot = key.firstIndex(of: "."), dot != key.startIndex,
            dot != key.index(before: key.endIndex)
        else { return nil }
        self.namespace = String(key[key.startIndex..<dot])
        self.value = String(key[key.index(after: dot)...])
    }

    public var key: String { namespace + "." + value }

    public static func < (lhs: FeatureKey, rhs: FeatureKey) -> Bool {
        lhs.key < rhs.key
    }
}

// MARK: - Catalog input types

/// Input schema for the taste engine, mirroring the app's bundled catalog
/// (`apps/ios/Resources/data.json`) so extraction runs against exactly the
/// data the app ships. Parsing from the app's positional JSON happens in the
/// app boundary layer; FLTaste takes these typed values.
public struct CatalogIngredient: Hashable, Sendable {
    public let id: IngredientID
    public let name: String
    /// All per-100g values, matching the app's nutrition table.
    public let caloriesPer100g: Double
    public let proteinPer100g: Double
    public let carbsPer100g: Double
    public let fatPer100g: Double
    public let fiberPer100g: Double

    public init(
        id: IngredientID, name: String, caloriesPer100g: Double, proteinPer100g: Double,
        carbsPer100g: Double, fatPer100g: Double, fiberPer100g: Double
    ) {
        self.id = id
        self.name = name
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g = carbsPer100g
        self.fatPer100g = fatPer100g
        self.fiberPer100g = fiberPer100g
    }
}

/// A recipe as the app schema defines it: positional arrays become typed
/// fields here, with the tag bitmask decoded against `CatalogTag`.
public struct CatalogRecipe: Hashable, Sendable {
    public struct IngredientUse: Hashable, Sendable {
        public let id: IngredientID
        public let grams: Double

        public init(id: IngredientID, grams: Double) {
            self.id = id
            self.grams = grams
        }
    }

    public let id: RecipeID
    public let title: String
    public let timeMinutes: Int
    public let servings: Int
    public let requiredIngredients: [IngredientUse]
    public let optionalIngredients: [IngredientUse]
    /// Step text, newline-separated ("1. Cook rice..."), as shipped.
    public let instructions: String
    public let tagBitmask: Int

    public init(
        id: RecipeID, title: String, timeMinutes: Int, servings: Int,
        requiredIngredients: [IngredientUse], optionalIngredients: [IngredientUse],
        instructions: String, tagBitmask: Int
    ) {
        self.id = id
        self.title = title
        self.timeMinutes = timeMinutes
        self.servings = servings
        self.requiredIngredients = requiredIngredients
        self.optionalIngredients = optionalIngredients
        self.instructions = instructions
        self.tagBitmask = tagBitmask
    }

    public func hasTag(_ tag: CatalogTag) -> Bool {
        tagBitmask & tag.bit != 0
    }
}

/// The 12 catalog tags, bit-for-bit the app's `RecipeTags` bitmask
/// (apps/ios/Domain/Models/Recipe.swift). The three cuisine tags are the
/// catalog's only cuisine vocabulary.
public enum CatalogTag: Int, CaseIterable, Sendable {
    case quick = 0
    case vegetarian = 1
    case vegan = 2
    case asian = 3
    case breakfast = 4
    case budget = 5
    case comfort = 6
    case mediterranean = 7
    case mexican = 8
    case highProtein = 9
    case lowCarb = 10
    case onePot = 11

    public var bit: Int { 1 << rawValue }

    /// Tags that name a cuisine (feature namespace `cuisine.*`).
    public static let cuisines: [CatalogTag] = [.asian, .mediterranean, .mexican]

    /// The remaining tags describe style and route (feature namespace
    /// `style.*`).
    public static let styles: [CatalogTag] = [
        .quick, .vegetarian, .vegan, .breakfast, .budget, .comfort, .highProtein, .lowCarb,
        .onePot,
    ]

    public var featureValue: String {
        switch self {
        case .highProtein: return "high_protein"
        case .lowCarb: return "low_carb"
        case .onePot: return "one_pot"
        default: return String(describing: self)
        }
    }
}

/// The ingredient and recipe catalog the engine ranks over. Extraction and
/// the feature space are built from this; a catalog change that adds an
/// ingredient changes the feature space and must bump the feature version.
public struct RecipeCatalog: Sendable {
    public let ingredients: [IngredientID: CatalogIngredient]
    public let recipes: [RecipeID: CatalogRecipe]

    public init(ingredients: [CatalogIngredient], recipes: [CatalogRecipe]) {
        var byID: [IngredientID: CatalogIngredient] = [:]
        for ingredient in ingredients { byID[ingredient.id] = ingredient }
        var recipesByID: [RecipeID: CatalogRecipe] = [:]
        for recipe in recipes { recipesByID[recipe.id] = recipe }
        self.ingredients = byID
        self.recipes = recipesByID
    }
}
