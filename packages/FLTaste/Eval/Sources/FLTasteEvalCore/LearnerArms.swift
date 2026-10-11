import Foundation
import FLTaste
import FLTasteSim

// The four model families implemented inside Eval (family 2 wraps Part 1's
// engine; see EngineArm.swift). All are Foundation-only, deterministic, and
// fold the same canonical event stream the engine sees. Every arm's
// randomness derives from the arm seed; every observation carries the
// exposure weight of DESIGN.md §2 and a per-class recency decay from
// DESIGN.md §3 so the families differ in MODEL, not in preprocessing.

/// Shared per-recipe feature cache: sparse extraction once per recipe, all
/// of it precomputed at construction. Read-only afterwards, so one instance
/// is safely shared by the campaign's worker threads.
public final class FeatureCache: @unchecked Sendable {
    public let extractor: FeatureExtractor
    public let catalog: RecipeCatalog
    private let cache: [RecipeID: SparseVector]

    public init(catalog: RecipeCatalog) {
        self.catalog = catalog
        self.extractor = FeatureExtractor(catalog: catalog)
        var built: [RecipeID: SparseVector] = [:]
        for (id, recipe) in catalog.recipes {
            built[id] = extractor.extract(recipe, catalog: catalog)
        }
        self.cache = built
    }

    public func features(_ recipe: CatalogRecipe) -> SparseVector {
        cache[recipe.id] ?? extractor.extract(recipe, catalog: catalog)
    }

    public func features(_ id: RecipeID) -> SparseVector? {
        cache[id]
    }
}

/// One labeled observation for the regression-style learners.
struct LearnerObservation {
    let components: [SparseComponent]
    let reward: Double  // in [-1, 1]
    let weight: Double
}

/// The evidence stream every learner folds: observations from behavioral
/// events, with RewardScale semantics (FLTaste Model/TasteModel.swift).
enum Evidence {
    static func exposureWeight(_ context: ExposureContext?) -> Double {
        guard let context else { return 1.0 }
        guard context.feasibleCandidates > 0 else { return 0.15 }
        let share = Double(context.shownCandidates ?? context.feasibleCandidates)
            / Double(context.feasibleCandidates)
        return min(1.0, max(0.15, share))
    }

    /// Per-class half-lives (days), DESIGN.md §3.
    static func halfLife(for event: TasteEvent) -> Double {
        switch event.kind {
        case .cooked: return 120
        case .saved: return 60
        case .substituted: return 90
        case .skipped, .leChefFeedback: return 45
        case .opened, .viewed: return 30
        default: return 120
        }
    }

    /// Observation(s) for one event, or nil when the event carries no
    /// reward-grade evidence. Rewards mirror `RewardScale` exactly.
    static func observations(
        for event: TasteEvent, cache: FeatureCache
    ) -> [LearnerObservation] {
        let featureWeight = exposureWeight(event.exposure)
        func observation(_ id: RecipeID, _ reward: Double) -> LearnerObservation? {
            guard let features = cache.features(id) else { return nil }
            return LearnerObservation(
                components: features.components, reward: reward, weight: featureWeight)
        }
        switch event.kind {
        case .cooked(let recipe, let rating, let wouldMakeAgain):
            var result: [LearnerObservation] = []
            if let stars = rating?.value {
                // RewardScale.cookedBase: (stars - 3) * 0.5, so 5 → +1, 1 → -1.
                let reward = 0.5 * Double(stars - 3)
                if let obs = observation(recipe, reward) { result.append(obs) }
            } else if let obs = observation(recipe, RewardScale.unratedCook) {
                result.append(obs)
            }
            if let again = wouldMakeAgain {
                let bonus = again ? RewardScale.wouldMakeAgainBonus : -RewardScale.wouldMakeAgainBonus
                if let obs = observation(recipe, bonus) { result.append(obs) }
            }
            return result
        case .saved(let recipe):
            return observation(recipe, RewardScale.saved).map { [$0] } ?? []
        case .opened(let recipe):
            return observation(recipe, RewardScale.opened).map { [$0] } ?? []
        case .viewed(let recipe):
            return observation(recipe, RewardScale.viewed).map { [$0] } ?? []
        case .skipped(let recipe, let reason):
            return observation(recipe, RewardScale.skip[reason] ?? -0.3).map { [$0] } ?? []
        case .leChefFeedback(let recipe, let feedback):
            return observation(recipe, RewardScale.leChef[feedback.type] ?? -0.3).map { [$0] } ?? []
        case .substituted(let recipe, _, _, let mode):
            guard mode == .preferred else { return [] }
            return observation(recipe, RewardScale.preferredSubstitution).map { [$0] } ?? []
        case .profileEdit(.setPreference(let feature, let polarity)):
            // A stated preference: a +1/-1 pseudo-observation on the single
            // feature, full weight, no decay.
            guard let index = cache.extractor.space.index(of: feature) else { return [] }
            let reward: Double = polarity == .like ? 1.0 : -1.0
            return [LearnerObservation(components: [SparseComponent(index: index, value: 1)], reward: reward, weight: 1.0)]
        default:
            return []
        }
    }

    /// Recency multiplier for an event at fold time, anchored at the newest
    /// event (same anchor rule as the engine).
    static func recency(_ event: TasteEvent, anchor: Instant?) -> Double {
        guard let anchor else { return 1.0 }
        let ageDays = Double(event.at.days(to: anchor))
        guard ageDays > 0 else { return 1.0 }
        return pow(0.5, ageDays / halfLife(for: event))
    }

    /// All labeled observations from a canonical event stream.
    static func fold(
        _ events: [TasteEvent], cache: FeatureCache
    ) -> (observations: [LearnerObservation], anchor: Instant?) {
        let anchor = events.map(\.at).max()
        var result: [LearnerObservation] = []
        for event in events {
            let recency = Self.recency(event, anchor: anchor)
            for observation in observations(for: event, cache: cache) {
                result.append(
                    LearnerObservation(
                        components: observation.components, reward: observation.reward,
                        weight: observation.weight * recency))
            }
        }
        return (result, anchor)
    }

    /// Small rule-aligned prior for shrinkage: the fixed-vocab features the
    /// rule ranker's formula rewards (time bonus, quick style, protein),
    /// zero on taste features. Shrinking toward this is "toward the rule
    /// baseline" without hand-labeling any ingredient.
    static func rulePrior(space: FeatureSpace) -> [Double] {
        var prior = [Double](repeating: 0.0, count: space.dimension)
        func add(_ key: FeatureKey, _ value: Double) {
            guard let index = space.index(of: key) else { return }
            prior[index] = value
        }
        add(FeatureKey(namespace: "time", value: "le15"), 0.4)
        add(FeatureKey(namespace: "time", value: "le30"), 0.2)
        add(FeatureKey(namespace: "time", value: "le60"), -0.1)
        add(FeatureKey(namespace: "time", value: "gt60"), -0.3)
        add(FeatureKey(namespace: "style", value: "quick"), 0.3)
        add(FeatureKey(namespace: "nutrition.protein", value: "gt30"), 0.3)
        return prior
    }
}

// MARK: - Family 1: Beta trust vector per source and feature

/// Sam's trust-vector design applied to taste: for every (evidence source,
/// feature) pair a Beta posterior over "this feature is good"; posterior
/// means combine across sources with fixed per-source reliability weights
/// into a utility proxy. Pseudocounts shrink to neutral; counts carry the
/// exposure weight and per-class recency of the shared evidence stream.
final class TrustVectorState: ArmState, @unchecked Sendable {
    static let sources = ["cooked", "saved", "opened", "viewed", "skipped", "lechef", "substituted", "explicit"]
    static let reliability: [String: Double] = [
        "cooked": 1.0, "saved": 0.9, "opened": 0.4, "viewed": 0.2,
        "skipped": 0.7, "lechef": 0.5, "substituted": 0.6, "explicit": 1.0,
    ]

    private let cache: FeatureCache
    private let dimension: Int
    // [sourceIndex * dimension + featureIndex]
    private var alpha: [Double]
    private var beta: [Double]
    private var scoreByRecipe: [RecipeID: Double] = [:]
    private var scores: [RecipeID: Double] = [:]

    init(cache: FeatureCache, events: [TasteEvent]) {
        self.cache = cache
        self.dimension = cache.extractor.space.dimension
        let count = TrustVectorState.sources.count * dimension
        self.alpha = [Double](repeating: 1.0, count: count)  // uniform prior
        self.beta = [Double](repeating: 1.0, count: count)
        fold(events)
        rebuildScores()
    }

    private func fold(_ events: [TasteEvent]) {
        let anchor = events.map(\.at).max()
        for event in events {
            guard let source = Self.source(of: event),
                  let sourceIndex = TrustVectorState.sources.firstIndex(of: source)
            else { continue }
            let weight = Evidence.exposureWeight(event.exposure)
                * Evidence.recency(event, anchor: anchor)
            for obs in Evidence.observations(for: event, cache: cache) {
                let positive = max(0.0, obs.reward)
                let negative = max(0.0, -obs.reward)
                for component in obs.components {
                    let base = sourceIndex * dimension + component.index
                    alpha[base] += weight * positive * component.value
                    beta[base] += weight * negative * component.value
                }
            }
        }
    }

    private static func source(of event: TasteEvent) -> String? {
        switch event.kind {
        case .saved: return "saved"
        case .opened: return "opened"
        case .viewed: return "viewed"
        case .skipped: return "skipped"
        case .leChefFeedback: return "lechef"
        case .substituted: return "substituted"
        case .profileEdit: return "explicit"
        // Servings edits and corrections carry no preference evidence here:
        // corrections are resolved by the engine's own fold, and servings
        // edits speak to portioning, not taste.
        case .editedServings, .correction: return nil
        case .cooked: return "cooked"
        }
    }

    private func rebuildScores() {
        scoreByRecipe = [:]
        // Combined weight over features: sum of source reliabilities times
        // posterior-signed mean, in [-1, 1].
        var combined = [Double](repeating: 0.0, count: dimension)
        for (sourceIndex, source) in TrustVectorState.sources.enumerated() {
            let reliability = TrustVectorState.reliability[source] ?? 0.5
            let base = sourceIndex * dimension
            for i in 0..<dimension {
                let mean = alpha[base + i] / (alpha[base + i] + beta[base + i])
                combined[i] += reliability * (2.0 * mean - 1.0)
            }
        }
        for (id, recipe) in cache.catalog.recipes {
            let features = cache.features(recipe)
            scoreByRecipe[id] = features.dot(combined)
        }
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                scoreByRecipe[candidate.recipe.id].map { (candidate.recipe.id, $0) }
            })
        return ArmOrdering.ordered(candidates) { candidate in
            self.scoreByRecipe[candidate.recipe.id] ?? -Double.infinity
        }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct TrustVectorArm: ArmFactory {
    public let id = "trust-vector"
    public let rationale =
        "Family 1: Sam's Beta posteriors per evidence source and feature, reliability-weighted — the trust-vector design applied to taste."
    public let family = "family-1"
    private let cache: FeatureCache

    public init(cache: FeatureCache) {
        self.cache = cache
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        TrustVectorState(cache: cache, events: events)
    }
}

// MARK: - Family 3: regularized logistic regression, shrinkage to rule prior

final class LogisticState: ArmState, @unchecked Sendable {
    private let cache: FeatureCache
    private let dimension: Int
    private var weights: [Double]
    private var scoreByRecipe: [RecipeID: Double] = [:]
    private var scores: [RecipeID: Double] = [:]

    // Fixed training schedule: full-batch gradient descent, deterministic.
    static let iterations = 300
    static let learningRate = 0.5
    static let priorPrecision = 0.25  // shrinkage strength λ (σ₀ = 2)

    init(cache: FeatureCache, events: [TasteEvent]) {
        self.cache = cache
        self.dimension = cache.extractor.space.dimension
        self.weights = Evidence.rulePrior(space: cache.extractor.space)
        train(with: events)
        rebuildScores()
    }

    private func train(with events: [TasteEvent]) {
        let (observations, _) = Evidence.fold(events, cache: cache)
        guard !observations.isEmpty else { return }
        let prior = Evidence.rulePrior(space: cache.extractor.space)
        var gradient = [Double](repeating: 0, count: dimension)
        for iteration in 0..<LogisticState.iterations {
            gradient = [Double](repeating: 0, count: dimension)
            for observation in observations {
                let prediction = sigmoid(dot(observation.components, weights))
                // reward in [-1, 1] maps to label in [0, 1].
                let error = observation.weight * (prediction - (observation.reward + 1.0) / 2.0)
                for component in observation.components {
                    gradient[component.index] += error * component.value
                }
            }
            // Step size decays on a fixed schedule; deterministic.
            let step = LogisticState.learningRate / Double(iteration / 50 + 1)
            for i in 0..<dimension {
                let shrink = LogisticState.priorPrecision * (weights[i] - prior[i])
                weights[i] -= step * (gradient[i] + shrink)
            }
        }
    }

    private func rebuildScores() {
        scoreByRecipe = [:]
        for (id, recipe) in cache.catalog.recipes {
            let features = cache.features(recipe)
            scoreByRecipe[id] = features.dot(weights)
        }
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                scoreByRecipe[candidate.recipe.id].map { (candidate.recipe.id, $0) }
            })
        return ArmOrdering.ordered(candidates) { candidate in
            self.scoreByRecipe[candidate.recipe.id] ?? -Double.infinity
        }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct LogisticArm: ArmFactory {
    public let id = "logistic-l2"
    public let rationale =
        "Family 3: L2-regularized logistic regression on cooked/saved/skipped evidence, shrunk toward a rule-aligned prior."
    public let family = "family-3"
    private let cache: FeatureCache

    public init(cache: FeatureCache) {
        self.cache = cache
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        LogisticState(cache: cache, events: events)
    }
}

// MARK: - Family 4: pairwise learning-to-rank (RankNet-style)

final class PairwiseState: ArmState, @unchecked Sendable {
    private let cache: FeatureCache
    private let dimension: Int
    private var weights: [Double]
    private var scoreByRecipe: [RecipeID: Double] = [:]
    private var scores: [RecipeID: Double] = [:]

    static let epochs = 5
    static let learningRate = 0.1
    static let priorPrecision = 0.1

    init(cache: FeatureCache, events: [TasteEvent]) {
        self.cache = cache
        self.dimension = cache.extractor.space.dimension
        self.weights = [Double](repeating: 0.0, count: dimension)
        train(with: events)
        rebuildScores()
    }

    /// Training pairs: within one session (shared timestamp), the cooked
    /// recipe beats the shown-and-not-cooked alternatives when the cook was
    /// liked, and loses when disliked; saved recipes beat their session's
    /// other shown items; skipped items lose to the shown alternatives.
    private struct Pair {
        let positive: [SparseComponent]
        let negative: [SparseComponent]
        let weight: Double
    }

    private func train(with events: [TasteEvent]) {
        // Group behavioral events by timestamp (a session's events share
        // `at`); exposure weight comes from the session's events.
        var byTime: [Int64: [TasteEvent]] = [:]
        for event in events where event.exposure != nil {
            byTime[event.at.millisecondsSinceEpoch, default: []].append(event)
        }
        var pairs: [Pair] = []
        let anchor = events.map(\.at).max()
        // Sorted by timestamp: SGD update order must be deterministic.
        for time in byTime.keys.sorted() {
            let sessionEvents = byTime[time]!
            let viewed = sessionEvents.compactMap { event -> RecipeID? in
                if case .viewed(let recipe) = event.kind { return recipe }
                return nil
            }
            guard viewed.count > 1 else { continue }
            for event in sessionEvents {
                let recency = Evidence.recency(event, anchor: anchor)
                let exposure = Evidence.exposureWeight(event.exposure)
                let weight = exposure * recency
                switch event.kind {
                case .cooked(let recipe, let rating, _):
                    guard let stars = rating?.value else { continue }
                    let reward = 0.5 * Double(stars - 3)
                    guard abs(reward) > 0.01 else { continue }
                    for other in viewed where other != recipe {
                        pairs.append(
                            reward > 0
                                ? Pair(positive: features(of: recipe), negative: features(of: other), weight: weight)
                                : Pair(positive: features(of: other), negative: features(of: recipe), weight: weight))
                    }
                case .saved(let recipe):
                    for other in viewed where other != recipe {
                        pairs.append(Pair(positive: features(of: recipe), negative: features(of: other), weight: weight))
                    }
                case .skipped(let recipe, _):
                    for other in viewed where other != recipe {
                        pairs.append(Pair(positive: features(of: other), negative: features(of: recipe), weight: weight))
                    }
                default:
                    continue
                }
            }
        }
        guard !pairs.isEmpty else { return }
        for _ in 0..<PairwiseState.epochs {
            for pair in pairs {
                let positiveScore = dot(pair.positive, weights)
                let negativeScore = dot(pair.negative, weights)
                let gradient = sigmoid(-(positiveScore - negativeScore))
                for component in pair.positive {
                    weights[component.index] += PairwiseState.learningRate * pair.weight * gradient * component.value
                }
                for component in pair.negative {
                    weights[component.index] -= PairwiseState.learningRate * pair.weight * gradient * component.value
                }
                for i in 0..<dimension {
                    weights[i] -= PairwiseState.learningRate * PairwiseState.priorPrecision * weights[i]
                }
            }
        }
    }

    private func features(of id: RecipeID) -> [SparseComponent] {
        cache.features(id)?.components ?? []
    }

    private func rebuildScores() {
        scoreByRecipe = [:]
        for (id, recipe) in cache.catalog.recipes {
            scoreByRecipe[id] = cache.features(recipe).dot(weights)
        }
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                scoreByRecipe[candidate.recipe.id].map { (candidate.recipe.id, $0) }
            })
        return ArmOrdering.ordered(candidates) { candidate in
            self.scoreByRecipe[candidate.recipe.id] ?? -Double.infinity
        }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct PairwiseArm: ArmFactory {
    public let id = "pairwise-ltr"
    public let rationale =
        "Family 4: pairwise learning-to-rank (RankNet gradient on within-session chosen-vs-shown pairs)."
    public let family = "family-4"
    private let cache: FeatureCache

    public init(cache: FeatureCache) {
        self.cache = cache
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        PairwiseState(cache: cache, events: events)
    }
}

// MARK: - Family 5: small embedding model

/// Feature weights plus a per-recipe k-dim embedding scored against a
/// learned household vector: score(r) = w·x_r + u·m_r. The embedding is
/// initialized by a deterministic random projection of the recipe's features
/// and refined from rewards — a two-component model that can like two
/// recipes with identical features differently, which a linear model cannot.
final class EmbeddingState: ArmState, @unchecked Sendable {
    static let k = 8
    static let passes = 3
    static let learningRateFeature = 0.05
    static let learningRateEmbedding = 0.02

    private let cache: FeatureCache
    private let dimension: Int
    private var weights: [Double]
    private var household: [Double]  // u, k dims
    private var embeddings: [RecipeID: [Double]]  // m_r, k dims
    private var scoreByRecipe: [RecipeID: Double] = [:]
    private var scores: [RecipeID: Double] = [:]

    init(cache: FeatureCache, events: [TasteEvent], seed: UInt64) {
        self.cache = cache
        self.dimension = cache.extractor.space.dimension
        self.weights = Evidence.rulePrior(space: cache.extractor.space)
        var rng = SeededRNG(seed: SeedDeriver.child(seed, "embedding-init", 0))
        self.household = (0..<EmbeddingState.k).map { _ in rng.nextNormal() * 0.1 }
        var projection: [Double] = (0..<(EmbeddingState.k * dimension)).map { _ in rng.nextNormal() * 0.1 }
        self.embeddings = [:]
        for (id, recipe) in cache.catalog.recipes {
            let features = cache.features(recipe)
            var embedding = [Double](repeating: 0.0, count: EmbeddingState.k)
            for component in features.components {
                for j in 0..<EmbeddingState.k {
                    embedding[j] += projection[j * dimension + component.index] * component.value
                }
            }
            embeddings[id] = embedding
        }
        train(with: events)
        rebuildScores()
    }

    private func train(with events: [TasteEvent]) {
        guard !events.isEmpty else { return }
        let anchor = events.map(\.at).max()
        var rewards: [(features: [SparseComponent], reward: Double, weight: Double, recipe: RecipeID?)] = []
        for event in events {
            let weight = Evidence.exposureWeight(event.exposure)
                * Evidence.recency(event, anchor: anchor)
            for observation in Evidence.observations(for: event, cache: cache) {
                rewards.append(
                    (observation.components, observation.reward,
                     weight, Self.recipe(of: event)))
            }
        }
        guard !rewards.isEmpty else { return }
        for _ in 0..<EmbeddingState.passes {
            for observation in rewards {
                let linear = dot(observation.features, weights)
                let embeddingComponent: Double
                if let recipeId = observation.recipe, let embedding = embeddings[recipeId] {
                    embeddingComponent = zip(household, embedding).reduce(0) { $0 + $1.0 * $1.1 }
                } else {
                    embeddingComponent = 0.0
                }
                let residual = observation.weight * (observation.reward - (linear + embeddingComponent))
                for component in observation.features {
                    weights[component.index] += EmbeddingState.learningRateFeature * residual * component.value
                }
                if let recipeId = observation.recipe, let embedding = embeddings[recipeId] {
                    for j in 0..<EmbeddingState.k {
                        household[j] += EmbeddingState.learningRateEmbedding * residual * embedding[j]
                        embeddings[recipeId]![j] += EmbeddingState.learningRateEmbedding * residual * household[j]
                    }
                }
            }
        }
    }

    private static func recipe(of event: TasteEvent) -> RecipeID? {
        switch event.kind {
        case .cooked(let recipe, _, _): return recipe
        case .saved(let recipe): return recipe
        case .opened(let recipe): return recipe
        case .viewed(let recipe): return recipe
        case .skipped(let recipe, _): return recipe
        case .leChefFeedback(let recipe, _): return recipe
        case .substituted(let recipe, _, _, _): return recipe
        default: return nil
        }
    }

    private func rebuildScores() {
        scoreByRecipe = [:]
        for (id, recipe) in cache.catalog.recipes {
            let linear = cache.features(recipe).dot(weights)
            let embeddingComponent = embeddings[id].map { embedding in
                zip(household, embedding).reduce(0) { $0 + $1.0 * $1.1 }
            } ?? 0.0
            scoreByRecipe[id] = linear + embeddingComponent
        }
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                scoreByRecipe[candidate.recipe.id].map { (candidate.recipe.id, $0) }
            })
        return ArmOrdering.ordered(candidates) { candidate in
            self.scoreByRecipe[candidate.recipe.id] ?? -Double.infinity
        }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct EmbeddingArm: ArmFactory {
    public let id = "embedding"
    public let rationale =
        "Family 5: linear features plus a per-recipe 8-dim embedding scored against a learned household vector."
    public let family = "family-5"
    private let cache: FeatureCache

    public init(cache: FeatureCache) {
        self.cache = cache
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        EmbeddingState(cache: cache, events: events, seed: armSeed)
    }
}

// MARK: - Shared math

func sigmoid(_ x: Double) -> Double {
    if x >= 0 {
        return 1.0 / (1.0 + exp(-x))
    }
    let y = exp(x)
    return y / (1.0 + y)
}

func dot(_ components: [SparseComponent], _ weights: [Double]) -> Double {
    var result = 0.0
    for component in components {
        result += component.value * weights[component.index]
    }
    return result
}
