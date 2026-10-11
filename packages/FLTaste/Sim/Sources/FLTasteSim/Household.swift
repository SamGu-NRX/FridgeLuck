import Foundation
import FLTaste

/// One eater: a latent taste vector over Part 1's feature space, plus that
/// eater's own hard restrictions.
///
/// The latent vector is dense over `FeatureSpace.keys` and is the
/// ground truth a learning model never sees. Utilities are
/// `extract(recipe).dot(latent)` — exactly the representation a learned
/// weight vector would live in, so scorers can compare learned vectors to
/// the truth directly.
public struct Eater: Sendable {
    public let id: EaterID
    /// Dense weights over the feature space; mutated only by drift.
    public var latent: [Double]
    /// This eater's hard restrictions. Hard filters are never weakened by
    /// taste and survive any learning reset (SPEC 3.3).
    public var restrictions: [Restriction]
}

/// A household: one or two eaters. The household's hard restrictions are the
/// union of the eaters' — one phone, one dinner, so a meal must be legal for
/// everyone (overhaul finding 6).
public struct Household: Sendable {
    /// Eaters are mutable so drift and mid-history shifts can update latent
    /// taste and restrictions; the household itself is a value type.
    public var eaters: [Eater]

    /// Union of every eater's restrictions, de-duplicated by (kind, target).
    /// A recipe is household-legal only when it is legal under every
    /// restriction in this union.
    public var restrictionUnion: [Restriction] {
        var seen: Set<String> = []
        var union: [Restriction] = []
        for restriction in eaters.flatMap({ $0.restrictions }) {
            let key = restriction.kind.rawValue + ":" + restriction.target
            if seen.insert(key).inserted { union.append(restriction) }
        }
        return union
    }

    public var eaterIDs: [EaterID] { eaters.map(\.id) }
}

/// Draws a household from a seed: latent tastes, hard restrictions.
///
/// Taste shape, per eater: a handful of liked and disliked ingredients, one
/// liked and one disliked cuisine, a couple of style and technique
/// alignments, a spice affinity, and time/effort posture. Everything is a
/// weight on a real `FeatureKey` from the catalog's feature space, so any
/// catalog works and utilities are always meaningful.
public enum HouseholdFactory {

    /// Ingredient ids eligible for drawn allergies, filtered to whatever the
    /// catalog actually carries. Common severe allergens first.
    static let allergyCandidates = [
        "peanut_butter", "peanuts", "egg", "milk", "cheese", "butter",
        "shrimp", "fish_sauce", "soy_sauce", "tree_nuts", "walnut", "sesame",
    ]

    public static func generate(config: SimConfig, catalog: RecipeCatalog) -> Household {
        var rng = SeededRNG(seed: SeedDeriver.child(config.seed, "household", 0))
        let space = FeatureExtractor(catalog: catalog).space
        let ingredientKeys = space.keys.filter { $0.namespace == "ingredient" }
        let cuisineKeys = space.keys.filter { $0.namespace == "cuisine" }
        let styleKeys = space.keys.filter { $0.namespace == "style" }
        let techniqueKeys = space.keys.filter { $0.namespace == "technique" }

        var eaters: [Eater] = []
        for index in 0..<max(1, min(2, config.householdSize)) {
            let latent = drawLatent(
                &rng, space: space, ingredientKeys: ingredientKeys,
                cuisineKeys: cuisineKeys, styleKeys: styleKeys, techniqueKeys: techniqueKeys)
            eaters.append(
                Eater(
                    id: EaterID("e\(index + 1)")!,
                    latent: latent,
                    restrictions: drawRestrictions(&rng, config: config, catalog: catalog)))
        }
        return Household(eaters: eaters)
    }

    // MARK: Latent taste

    private static func drawLatent(
        _ rng: inout SeededRNG, space: FeatureSpace,
        ingredientKeys: [FeatureKey], cuisineKeys: [FeatureKey],
        styleKeys: [FeatureKey], techniqueKeys: [FeatureKey]
    ) -> [Double] {
        var latent = [Double](repeating: 0.0, count: space.dimension)

        // Ingredients: 5-10 liked, 2-4 disliked. Weights in [-1.5, +1.8]:
        // one liked feature adds roughly one unit of utility, so a recipe
        // matching three liked ingredients beats one matching none by about
        // three softmax temperature units — decisive but not certain.
        func sampleKeys(_ keys: [FeatureKey], _ count: Int) -> [FeatureKey] {
            var pool = keys
            var picked: [FeatureKey] = []
            for _ in 0..<count {
                guard !pool.isEmpty else { break }
                let i = Int(rng.nextUniform() * Double(pool.count))
                picked.append(pool.remove(at: min(i, pool.count - 1)))
            }
            return picked
        }
        let likedIngredients = sampleKeys(ingredientKeys, 5 + Int(rng.nextUniform() * 6))
        for key in likedIngredients {
            if let i = space.index(of: key) { latent[i] += 0.6 + 1.2 * rng.nextUniform() }
        }
        let dislikedIngredients = sampleKeys(ingredientKeys, 2 + Int(rng.nextUniform() * 3))
        for key in dislikedIngredients {
            if let i = space.index(of: key) { latent[i] -= 0.6 + 1.0 * rng.nextUniform() }
        }

        // Cuisine: one liked (+0.8), one disliked (-0.5) among the three.
        let cuisinePicks = sampleKeys(cuisineKeys, min(2, cuisineKeys.count))
        for (offset, key) in cuisinePicks.enumerated() {
            if let i = space.index(of: key) { latent[i] += offset == 0 ? 0.8 : -0.5 }
        }

        // Style: 1-2 liked (+0.5), 1 disliked (-0.5).
        for key in sampleKeys(styleKeys, 1 + Int(rng.nextUniform() * 2)) {
            if let i = space.index(of: key) { latent[i] += 0.5 }
        }
        for key in sampleKeys(styleKeys, 1) {
            if let i = space.index(of: key) { latent[i] -= 0.5 }
        }

        // Technique: 1-2 liked (+0.5), occasionally one disliked (-0.4).
        for key in sampleKeys(techniqueKeys, 1 + Int(rng.nextUniform() * 2)) {
            if let i = space.index(of: key) { latent[i] += 0.5 }
        }
        if rng.nextUniform() < 0.35 {
            for key in sampleKeys(techniqueKeys, 1) {
                if let i = space.index(of: key) { latent[i] -= 0.4 }
            }
        }

        // Spice affinity r in {-1, 0, +1}; drives both spice.* weights and
        // the tooSpicy feedback path later.
        let heatRoll = rng.nextUniform()
        let heatAffinity: Double = heatRoll < 0.3 ? -1 : (heatRoll < 0.7 ? 0 : 1)
        if let hot = space.index(of: FeatureKey(namespace: "spice", value: "hot")) {
            latent[hot] += 0.7 * heatAffinity
        }
        if let none = space.index(of: FeatureKey(namespace: "spice", value: "none")) {
            latent[none] -= 0.3 * heatAffinity
        }

        // Time posture: most households are weeknight-short on time.
        if rng.nextUniform() < 0.7 {
            if let i = space.index(of: FeatureKey(namespace: "time", value: "gt60")) {
                latent[i] -= 0.6
            }
            if let i = space.index(of: FeatureKey(namespace: "time", value: "le30")) {
                latent[i] += 0.3
            }
        }

        // Effort posture: often avoid involved recipes.
        if rng.nextUniform() < 0.6 {
            if let i = space.index(of: FeatureKey(namespace: "effort", value: "involved")) {
                latent[i] -= 0.4
            }
        }
        if rng.nextUniform() < 0.4 {
            if let i = space.index(of: FeatureKey(namespace: "effort", value: "simple")) {
                latent[i] += 0.2
            }
        }

        // bias.one stays 0: the intercept is a model-side parameter, not
        // taste. nutrition/servings/cost/complexity stay 0 in v1 (documented
        // in SIM-ASSUMPTIONS.md).
        return latent
    }

    // MARK: Hard restrictions

    private static func drawRestrictions(
        _ rng: inout SeededRNG, config: SimConfig, catalog: RecipeCatalog
    ) -> [Restriction] {
        guard rng.nextUniform() < config.restrictionProbability else { return [] }
        if rng.nextUniform() < 0.6 {
            // Allergy: pick one candidate the catalog carries. Seeded draw —
            // Array.randomElement() would touch the system RNG.
            let available = allergyCandidates.filter { catalog.ingredients[IngredientID($0)!] != nil }
            guard !available.isEmpty else { return drawDiet(&rng, source: "setup") }
            let pick = available[Int(rng.nextUniform() * Double(available.count))]
            return [Restriction(kind: .allergy, target: pick, source: "setup")]
        }
        return drawDiet(&rng, source: "setup")
    }

    private static func drawDiet(_ rng: inout SeededRNG, source: String) -> [Restriction] {
        let diet = rng.nextUniform() < 0.8 ? "vegetarian" : "vegan"
        return [Restriction(kind: .diet, target: diet, source: source)]
    }
}
