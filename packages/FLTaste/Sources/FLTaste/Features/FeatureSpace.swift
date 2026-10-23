import Foundation

/// Version of the feature space and extraction rules. Bump whenever a
/// feature, an extraction rule, or the catalog-driven key set changes; the
/// serialized snapshot records it, and restore fails closed on a mismatch.
public let tasteFeaturesVersion = "taste-features-v1"

/// The fixed, ordered set of features the model weights.
///
/// Index assignment is derived once from a catalog by sorting the feature
/// keys, so the same catalog always yields the same indices. Buckets that do
/// not depend on the catalog (time, effort, servings, nutrition, spice, cost,
/// complexity, technique) are part of the fixed vocabulary below.
public struct FeatureSpace: Sendable {
    public let version: String
    /// Feature key by index; index is the position in this sorted array.
    public let keys: [FeatureKey]
    private let indexByKey: [FeatureKey: Int]

    /// Builds the space from a catalog: one `ingredient.*` key per catalog
    /// ingredient, plus the fixed namespaces.
    public init(catalog: RecipeCatalog) {
        var keys = Set<FeatureKey>()
        keys.insert(FeatureKey(namespace: "bias", value: "one"))
        for ingredient in catalog.ingredients.values {
            keys.insert(FeatureKey(namespace: "ingredient", value: ingredient.id.rawValue))
        }
        for tag in CatalogTag.cuisines {
            keys.insert(FeatureKey(namespace: "cuisine", value: tag.featureValue))
        }
        for tag in CatalogTag.styles {
            keys.insert(FeatureKey(namespace: "style", value: tag.featureValue))
        }
        for value in Self.timeBuckets { keys.insert(FeatureKey(namespace: "time", value: value)) }
        for value in Self.effortBuckets {
            keys.insert(FeatureKey(namespace: "effort", value: value))
        }
        for value in Self.servingsBuckets {
            keys.insert(FeatureKey(namespace: "servings", value: value))
        }
        for value in Self.calorieBuckets {
            keys.insert(FeatureKey(namespace: "nutrition.calorie", value: value))
        }
        for value in Self.proteinBuckets {
            keys.insert(FeatureKey(namespace: "nutrition.protein", value: value))
        }
        for value in Self.fiberBuckets {
            keys.insert(FeatureKey(namespace: "nutrition.fiber", value: value))
        }
        for value in Self.spiceBuckets { keys.insert(FeatureKey(namespace: "spice", value: value)) }
        for value in Self.costBuckets { keys.insert(FeatureKey(namespace: "cost", value: value)) }
        for value in Self.complexityBuckets {
            keys.insert(FeatureKey(namespace: "complexity", value: value))
        }
        for name in Self.techniqueNames {
            keys.insert(FeatureKey(namespace: "technique", value: name))
        }
        self.version = tasteFeaturesVersion
        self.keys = keys.sorted()
        self.indexByKey = Dictionary(uniqueKeysWithValues: keys.sorted().enumerated().map {
            ($1, $0)
        })
    }

    public var dimension: Int { keys.count }

    public func index(of key: FeatureKey) -> Int? {
        indexByKey[key]
    }

    /// Inverse lookup used by explanations and profile sentences.
    public func key(at index: Int) -> FeatureKey? {
        keys.indices.contains(index) ? keys[index] : nil
    }

    // MARK: Bucket vocabularies (see FEATURES.md for the rules)

    static let timeBuckets = ["le15", "le30", "le60", "gt60"]
    static let effortBuckets = ["simple", "moderate", "involved"]
    static let servingsBuckets = ["one", "two", "threeToFour", "fivePlus"]
    static let calorieBuckets = ["le400", "400to650", "651to900", "gt900"]
    static let proteinBuckets = ["lt15", "15to30", "gt30"]
    static let fiberBuckets = ["lt6", "ge6"]
    static let spiceBuckets = ["none", "mild", "hot"]
    static let costBuckets = ["budget", "standard"]
    static let complexityBuckets = ["le5", "6to8", "gt8"]

    /// Instruction keywords mapped to a technique. Matching is
    /// case-insensitive substring search over the lowercased instructions;
    /// every match is recorded (a recipe can use several techniques).
    static let techniqueKeywords: [(name: String, needles: [String])] = [
        ("stirfry", ["stir-fry", "stir fry", "fry", "wok"]),
        ("boil", ["boil"]),
        ("simmer", ["simmer"]),
        ("bake", ["bake"]),
        ("roast", ["roast"]),
        ("grill", ["grill"]),
        ("steam", ["steam"]),
        ("marinate", ["marinate", "marinade"]),
        ("saute", ["sauté", "saute"]),
        ("toast", ["toast"]),
        ("blend", ["blend"]),
        ("mash", ["mash"]),
    ]

    static let techniqueNames = techniqueKeywords.map(\.name)

    /// Ingredient ids that carry heat or mild aromatics in the 50-ingredient
    /// catalog. The catalog has no dedicated spice metadata, so v1 derives
    /// spice level from this fixed list (see FEATURES.md).
    static let hotIngredientIDs: Set<String> = ["red_pepper_flakes"]
    static let mildIngredientIDs: Set<String> = ["ginger", "cumin"]
}
