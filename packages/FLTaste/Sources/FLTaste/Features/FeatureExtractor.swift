import Foundation

/// One sparse component. A named struct (not a tuple) so the vector can
/// synthesize Hashable/Equatable.
public struct SparseComponent: Hashable, Sendable {
    public let index: Int
    public let value: Double

    public init(index: Int, value: Double) {
        self.index = index
        self.value = value
    }
}

/// A sparse feature vector: components sorted by index. All values
/// are non-negative; the intercept is always present.
public struct SparseVector: Hashable, Sendable {
    public let components: [SparseComponent]

    init(components: [SparseComponent]) {
        self.components = components
    }

    public var isNotEmpty: Bool { !components.isEmpty }

    /// Dot product against a dense weight vector, reading only the sparse
    /// support.
    public func dot(_ weights: [Double]) -> Double {
        var sum = 0.0
        for component in components where component.index < weights.count {
            sum += weights[component.index] * component.value
        }
        return sum
    }

    /// Dot product restricted to a set of indices — used for ablation checks
    /// in explanations.
    public func dot(_ weights: [Double], keeping indices: Set<Int>) -> Double {
        var sum = 0.0
        for component in components
        where indices.contains(component.index) && component.index < weights.count {
            sum += weights[component.index] * component.value
        }
        return sum
    }

    /// A unit vector on one feature — stated preferences and tests address
    /// a single feature this way. Unknown keys produce the zero vector.
    static func single(space: FeatureSpace, key: FeatureKey, value: Double) -> SparseVector {
        guard let index = space.index(of: key) else { return SparseVector(components: []) }
        return SparseVector(components: [SparseComponent(index: index, value: value)])
    }
}

/// Extracts `taste-features-v1` vectors from catalog recipes.
///
/// Every rule here is specified in FEATURES.md and tested. The extractor is a
/// pure function of (recipe, catalog, space) — no state, no clock.
public struct FeatureExtractor: Sendable {
    public let space: FeatureSpace
    public let version: String

    public init(catalog: RecipeCatalog) {
        self.space = FeatureSpace(catalog: catalog)
        self.version = tasteFeaturesVersion
    }

    /// Per-serving nutrition computed exactly the way the app computes it
    /// (NutritionService): (per-100g / 100) * grams, summed over used
    /// ingredients, divided by servings.
    public func nutritionPerServing(
        _ recipe: CatalogRecipe, catalog: RecipeCatalog
    ) -> (calories: Double, protein: Double, fiber: Double) {
        var calories = 0.0, protein = 0.0, fiber = 0.0
        let uses = recipe.requiredIngredients + recipe.optionalIngredients
        for use in uses {
            guard let ingredient = catalog.ingredients[use.id] else { continue }
            let scale = use.grams / 100.0
            calories += ingredient.caloriesPer100g * scale
            protein += ingredient.proteinPer100g * scale
            fiber += ingredient.fiberPer100g * scale
        }
        let servings = max(1, recipe.servings)
        return (calories / Double(servings), protein / Double(servings), fiber / Double(servings))
    }

    public func extract(_ recipe: CatalogRecipe, catalog: RecipeCatalog) -> SparseVector {
        var components: [SparseComponent] = []

        func add(_ key: FeatureKey, _ value: Double = 1.0) {
            guard let index = space.index(of: key) else { return }
            components.append(SparseComponent(index: index, value: value))
        }

        add(FeatureKey(namespace: "bias", value: "one"), 1.0)

        // Ingredients: required at 1.0, optional at 0.5 (an optional
        // ingredient is present but skippable).
        for use in recipe.requiredIngredients {
            add(FeatureKey(namespace: "ingredient", value: use.id.rawValue), 1.0)
        }
        for use in recipe.optionalIngredients {
            add(FeatureKey(namespace: "ingredient", value: use.id.rawValue), 0.5)
        }

        // Cuisines and styles from the tag bitmask.
        for tag in CatalogTag.cuisines where recipe.hasTag(tag) {
            add(FeatureKey(namespace: "cuisine", value: tag.featureValue))
        }
        for tag in CatalogTag.styles where recipe.hasTag(tag) {
            add(FeatureKey(namespace: "style", value: tag.featureValue))
        }

        // Cook-time buckets.
        let timeBucket: String
        switch recipe.timeMinutes {
        case ...15: timeBucket = "le15"
        case ...30: timeBucket = "le30"
        case ...60: timeBucket = "le60"
        default: timeBucket = "gt60"
        }
        add(FeatureKey(namespace: "time", value: timeBucket))

        // Effort proxy: distinct ingredient kinds (the catalog has no effort
        // field).
        let kinds = Set(recipe.requiredIngredients.map(\.id))
            .union(recipe.optionalIngredients.map(\.id)).count
        let effortBucket = kinds <= 6 ? "simple" : (kinds <= 10 ? "moderate" : "involved")
        add(FeatureKey(namespace: "effort", value: effortBucket))

        // Servings buckets.
        let servingsBucket: String
        switch recipe.servings {
        case 1: servingsBucket = "one"
        case 2: servingsBucket = "two"
        case 3...4: servingsBucket = "threeToFour"
        default: servingsBucket = "fivePlus"
        }
        add(FeatureKey(namespace: "servings", value: servingsBucket))

        // Nutrition buckets from per-serving macros.
        let nutrition = nutritionPerServing(recipe, catalog: catalog)
        let calorieBucket: String
        switch nutrition.calories {
        case ...400: calorieBucket = "le400"
        case ...650: calorieBucket = "400to650"
        case ...900: calorieBucket = "651to900"
        default: calorieBucket = "gt900"
        }
        add(FeatureKey(namespace: "nutrition.calorie", value: calorieBucket))

        let proteinBucket: String
        switch nutrition.protein {
        case ..<15: proteinBucket = "lt15"
        case ...30: proteinBucket = "15to30"
        default: proteinBucket = "gt30"
        }
        add(FeatureKey(namespace: "nutrition.protein", value: proteinBucket))

        add(
            FeatureKey(namespace: "nutrition.fiber", value: nutrition.fiber < 6 ? "lt6" : "ge6"))

        // Spice level from the fixed ingredient lists.
        let usedIDs = Set(recipe.requiredIngredients.map(\.id.rawValue))
            .union(recipe.optionalIngredients.map(\.id.rawValue))
        let spice: String
        if !usedIDs.isDisjoint(with: FeatureSpace.hotIngredientIDs) {
            spice = "hot"
        } else if !usedIDs.isDisjoint(with: FeatureSpace.mildIngredientIDs) {
            spice = "mild"
        } else {
            spice = "none"
        }
        add(FeatureKey(namespace: "spice", value: spice))

        // Cost proxy: the catalog has no price data in v1, so the `budget`
        // tag is the whole cost signal (see FEATURES.md).
        add(
            FeatureKey(namespace: "cost",
                value: recipe.hasTag(.budget) ? "budget" : "standard"))

        // Techniques from instruction keywords.
        let lowered = recipe.instructions.lowercased()
        for (name, needles) in FeatureSpace.techniqueKeywords
        where needles.contains(where: lowered.contains) {
            add(FeatureKey(namespace: "technique", value: name))
        }

        // Complexity proxy: non-empty instruction lines.
        let stepCount = recipe.instructions.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let complexityBucket = stepCount <= 5 ? "le5" : (stepCount <= 8 ? "6to8" : "gt8")
        add(FeatureKey(namespace: "complexity", value: complexityBucket))

        return SparseVector(components: components.sorted { $0.index < $1.index })
    }
}
