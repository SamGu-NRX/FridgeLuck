import Foundation

/// Reward scales for behavioral events, in reward units where a neutral
/// cook is 0 and a loved cook is 1. Documented constants — part of the
/// model definition, not tunables. See DESIGN.md REWARD-1.
public enum RewardScale {
    public static let viewed: Double = 0.05
    public static let opened: Double = 0.25
    public static let saved: Double = 0.6
    /// Multiplier of `(rating - 3)`: rating 5 → +1, rating 1 → -1.
    public static let cookedBase: Double = 0.5
    public static let wouldMakeAgainBonus: Double = 0.25
    /// An unrated cook: they made it, which is weak positive evidence.
    public static let unratedCook: Double = 0.125
    public static let skip: [SkipReason: Double] = [
        .outOfTime: -0.25, .missingIngredients: -0.1, .changedMind: -0.6, .other: -0.3,
    ]
    public static let leChef: [LeChefFeedback.FeedbackType: Double] = [
        .tooSpicy: -0.5, .tookTooLong: -0.3, .tooBland: -0.4, .portionWrong: -0.2, .other: -0.3,
    ]
    /// A preferred substitution mildly down-weights the recipe's vector; a
    /// necessary substitution is availability, not taste (no observation).
    public static let preferredSubstitution: Double = -0.25
}

/// The behavioral layer of the taste model: per-eater Bayesian linear
/// posteriors folded from the event log.
///
/// Determinism: events are processed via `Fold.effectiveStream` (canonical
/// order, corrections applied, voids dropped); each update's feature
/// components are index-ordered; the age anchor is the last event's
/// timestamp. Refolding the same log yields bit-identical posteriors
/// regardless of ingest order.
public struct TasteModel: Sendable, Equatable {
    public let dimension: Int
    /// Behavioral posterior per eater. Stated-preference pseudo-observations
    /// are added at composition time (see `Ranker`), so a preference edit
    /// recomputes immediately and explicit state never leaks into the
    /// behavioral posteriors.
    public var behavioral: [EaterID: LinearGaussianPosterior]
    /// The fold anchor: the last event's timestamp (nil for an empty log).
    public let anchor: Instant?

    public init(
        events: [TasteEvent], extractor: FeatureExtractor, catalog: RecipeCatalog,
        config: TasteConfig
    ) {
        self.dimension = extractor.space.dimension
        self.behavioral = [:]
        self.anchor = events.map(\.at).max()

        let (stream, _) = Fold.effectiveStream(events)
        for event in stream {
            guard let observation = Self.observation(
                for: event, extractor: extractor, catalog: catalog, config: config,
                anchor: anchor)
            else { continue }

            switch event.eater {
            case .some(let eater):
                self.update(eater, with: observation, config: config)
            case .none:
                // Household event: credit every eater known so far, in
                // sorted order (same attribution rule as the explicit fold).
                for eater in behavioral.keys.sorted() {
                    self.update(eater, with: observation, config: config)
                }
            }
        }
    }

    private mutating func update(
        _ eater: EaterID, with observation: Observation, config: TasteConfig
    ) {
        var posterior = behavioral[eater] ?? LinearGaussianPosterior(
            dimension: dimension, priorVariance: config.priorWeightVariance)
        posterior.observe(
            observation.features, reward: observation.reward, weight: observation.weight,
            noiseVariance: config.observationNoiseVariance)
        behavioral[eater] = posterior
    }

    /// One weighted observation: features, reward, and the exposure-and-age
    /// weight. Nil when the event carries no reward signal.
    public struct Observation {
        let features: SparseVector
        let reward: Double
        let weight: Double
    }

    public static func observation(
        for event: TasteEvent, extractor: FeatureExtractor, catalog: RecipeCatalog,
        config: TasteConfig, anchor: Instant?
    ) -> Observation? {
        func observationFor(
            _ recipe: RecipeID, reward: Double, halfLifeDays: Double
        ) -> Observation? {
            guard let recipeRecord = catalog.recipes[recipe] else { return nil }
            let features = extractor.extract(recipeRecord, catalog: catalog)
            let exposure = exposureWeight(event.exposure, floor: config.exposureFloor)
            let age = ageWeight(eventAt: event.at, anchor: anchor, halfLifeDays: halfLifeDays)
            return Observation(features: features, reward: reward, weight: exposure * age)
        }

        switch event.kind {
        case .viewed(let recipe):
            return observationFor(
                recipe, reward: RewardScale.viewed,
                halfLifeDays: config.viewedEvidenceHalfLifeDays)
        case .opened(let recipe):
            return observationFor(
                recipe, reward: RewardScale.opened,
                halfLifeDays: config.openedEvidenceHalfLifeDays)
        case .saved(let recipe):
            return observationFor(
                recipe, reward: RewardScale.saved,
                halfLifeDays: config.savedEvidenceHalfLifeDays)
        case .cooked(let recipe, let rating, let wouldMakeAgain):
            var reward = rating.map { RewardScale.cookedBase * (Double($0.value) - 3.0) }
                ?? RewardScale.unratedCook
            if wouldMakeAgain == true { reward += RewardScale.wouldMakeAgainBonus }
            if wouldMakeAgain == false { reward -= RewardScale.wouldMakeAgainBonus }
            return observationFor(
                recipe, reward: reward, halfLifeDays: config.cookedEvidenceHalfLifeDays)
        case .skipped(let recipe, let reason):
            return observationFor(
                recipe, reward: RewardScale.skip[reason] ?? -0.3,
                halfLifeDays: config.skippedEvidenceHalfLifeDays)
        case .substituted(let recipe, _, _, let mode):
            guard mode == .preferred else { return nil }
            return observationFor(
                recipe, reward: RewardScale.preferredSubstitution,
                halfLifeDays: config.substitutionEvidenceHalfLifeDays)
        case .leChefFeedback(let recipe, let feedback):
            let reward = RewardScale.leChef[feedback.type] ?? -0.3
            return observationFor(
                recipe, reward: reward, halfLifeDays: config.feedbackEvidenceHalfLifeDays)
        case .editedServings:
            // Portion feedback informs profile sentences (M3), not the
            // linear taste weights, in v1.
            return nil
        case .profileEdit, .correction:
            // Explicit-layer events and corrections are applied by the
            // event fold, not as behavioral observations.
            return nil
        }
    }

    /// WEIGHTING-1 (availability as confound): acting on a recipe from a
    /// short shown list is weaker evidence of liking than a choice from
    /// real variety. `shown/feasible` is the opportunity share; below the
    /// floor the context is treated as "shown almost nothing" and clamped.
    public static func exposureWeight(_ exposure: ExposureContext?, floor: Double) -> Double {
        guard let exposure, let shown = exposure.shownCandidates else { return 1.0 }
        guard exposure.feasibleCandidates > 0 else { return floor }
        let share = Double(shown) / Double(exposure.feasibleCandidates)
        return max(floor, min(1.0, share))
    }

    /// Recency: evidence ages with a per-class half-life, anchored at the
    /// last event in the log (refolding recomputes exactly).
    public static func ageWeight(
        eventAt: Instant, anchor: Instant?, halfLifeDays: Double
    ) -> Double {
        guard let anchor, halfLifeDays > 0 else { return 1.0 }
        let ageDays = Double(eventAt.days(to: anchor))
        if ageDays <= 0 { return 1.0 }
        return Foundation.pow(0.5, ageDays / halfLifeDays)
    }
}
