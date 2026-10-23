import Foundation

/// Request for a ranking. `pantryFit` is keyed by candidate; a missing entry
/// is neutral (0.5). Popularity comes from the catalog unless overridden.
public struct RankInput: Sendable, Equatable {
    public var candidates: [RecipeID]
    public var pantryFit: [RecipeID: Double]
    public var popularityOverride: [RecipeID: Double]
    public var context: RankContext?

    public init(
        candidates: [RecipeID], pantryFit: [RecipeID: Double] = [:],
        popularityOverride: [RecipeID: Double] = [:], context: RankContext? = nil
    ) {
        self.candidates = candidates
        self.pantryFit = pantryFit
        self.popularityOverride = popularityOverride
        self.context = context
    }
}

public struct RankContext: Sendable, Equatable {
    /// Evaluation time; defaults to the model's fold anchor. Never wall
    /// clock — the engine is deterministic.
    public var now: Instant?
    /// Thompson exploration on/off. On by default.
    public var explore: Bool?

    public init(now: Instant? = nil, explore: Bool? = nil) {
        self.now = now
        self.explore = explore
    }
}

/// One ranked candidate. `score` is the exact value used for ordering
/// (exploration included when enabled); `expectedUtility` is the mean-based
/// value the explanation decomposes.
public struct RankedRecipe: Sendable, Equatable {
    public let recipe: RecipeID
    public let score: Double
    public let expectedUtility: Double
    public let pantryFit: Double
    public let popularity: Double
    /// Feature contributions to `expectedUtility`, strongest first.
    public let contributions: [Contribution]

    /// One term of the learned utility: `weight * featureValue ==
    /// contribution`, exactly. `evidenceCount` is the component's precision
    /// above prior precision — the effective number of unit observations
    /// attributable to that feature.
    public struct Contribution: Sendable, Equatable {
        public let feature: FeatureKey
        public let featureValue: Double
        public let weight: Double
        public let contribution: Double
        public let evidenceCount: Double
    }
}
