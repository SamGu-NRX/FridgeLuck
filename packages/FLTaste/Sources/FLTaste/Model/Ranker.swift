import Foundation

/// Composes per-eater behavioral posteriors with stated preferences,
/// merges households, applies hard filters, and scores candidates.
///
/// Layer contract (SPEC 3.3): explicit restrictions are applied BEFORE the
/// model sees any candidate — no weight configuration or Thompson draw can
/// resurface a hard-filtered recipe, because filtering happens on ingredient
/// identity, not on scores. Stated preferences are conjugate pseudo-
/// observations so an edit changes rankings immediately. Inferred taste is
/// the behavioral posterior.
struct Ranker {
    /// A stated preference is worth about 40 unit behavioral observations
    /// (variance 1/40): decisive for one cook, overruled by several.
    static let statedObservationVariance: Double = 0.025

    let config: TasteConfig
    let catalog: RecipeCatalog
    let extractor: FeatureExtractor
    let model: TasteModel
    let state: EngineState

    /// Effective per-eater posterior: behavioral posterior plus one pseudo-
    /// observation per active stated preference, in key order.
    func effectivePosterior(for eater: EaterID) -> LinearGaussianPosterior {
        var posterior = model.behavioral[eater]
            ?? LinearGaussianPosterior(
                dimension: extractor.space.dimension, priorVariance: config.priorWeightVariance)
        let layer = state.eaters[eater]?.explicit
        for key in layer?.stated.keys.sorted() ?? [] {
            guard let preference = layer?.stated[key] else { continue }
            let reward: Double = preference.polarity == .like ? 1.0 : -1.0
            posterior.observe(
                SparseVector.single(space: extractor.space, key: key, value: 1.0),
                reward: reward, weight: 1.0, noiseVariance: Self.statedObservationVariance)
        }
        return posterior
    }

    /// Household effective posterior: the household eats one meal, so the
    /// household score is the mean of eater scores — equivalently the
    /// posterior with element-wise averaged means and covariances.
    func householdPosterior() -> LinearGaussianPosterior? {
        let eaters = state.eaters.keys.sorted()
        guard !eaters.isEmpty else { return nil }
        let posteriors = eaters.map(effectivePosterior)
        var merged = LinearGaussianPosterior(
            dimension: extractor.space.dimension, priorVariance: config.priorWeightVariance)
        let n = Double(posteriors.count)
        for p in posteriors {
            for i in 0..<merged.dimension {
                merged.moment[i] += p.moment[i] / n
                merged.evidence[i] += p.evidence[i] / n
            }
            merged.totalEvidence += p.totalEvidence / n
        }
        merged.precision = Self.averagedPrecision(posteriors, dimension: merged.dimension, n: n)
        return merged
    }

    private static func averagedPrecision(
        _ posteriors: [LinearGaussianPosterior], dimension: Int, n: Double
    ) -> [Double] {
        var precision = Array(repeating: 0.0, count: dimension * dimension)
        for p in posteriors {
            for i in 0..<precision.count { precision[i] += p.precision[i] / n }
        }
        return precision
    }

    /// Hard-filtered and soft-never-suggest ingredient ids, given "now".
    func blockedIngredients(now: Instant) -> (hard: Set<IngredientID>, soft: Set<IngredientID>) {
        var hard = Set<IngredientID>()
        for restriction in state.household.restrictions {
            hard.formUnion(catalog.blockedIngredients(target: restriction.target))
        }
        for eater in state.eaters.keys.sorted() {
            for restriction in state.eaters[eater]?.explicit.restrictions ?? [] {
                hard.formUnion(catalog.blockedIngredients(target: restriction.target))
            }
        }
        var soft = Set<IngredientID>()
        for (ingredient, record) in state.household.neverSuggest {
            let age = Double(record.addedAt.days(to: now))
            if age >= 0, age < Double(config.softDismissalExpiryDays) {
                soft.insert(ingredient)
            }
        }
        for eater in state.eaters.keys.sorted() {
            for (ingredient, record) in state.eaters[eater]?.explicit.neverSuggest ?? [:] {
                let age = Double(record.addedAt.days(to: now))
                if age >= 0, age < Double(config.softDismissalExpiryDays) {
                    soft.insert(ingredient)
                }
            }
        }
        return (hard, soft)
    }

    /// Ranks the feasible candidates. Hard-filtered recipes are dropped
    /// before any model math; unknown recipes are dropped as well.
    func rank(_ input: RankInput, rng: inout SeededRNG) -> [RankedRecipe] {
        let now = input.context?.now ?? model.anchor ?? Instant(Date(timeIntervalSince1970: 0))
        let blocked = blockedIngredients(now: now)

        var candidates: [(RecipeID, CatalogRecipe)] = []
        for id in input.candidates {
            guard let recipe = catalog.recipes[id] else { continue }
            let used = Set(recipe.requiredIngredients.map(\.id))
                .union(Set(recipe.optionalIngredients.map(\.id)))
            if !used.isDisjoint(with: blocked.hard) { continue }
            if !used.isDisjoint(with: blocked.soft) { continue }
            candidates.append((id, recipe))
        }
        var seen = Set<RecipeID>()
        candidates = candidates.filter { seen.insert($0.0).inserted }

        guard let household = householdPosterior() else {
            return rankWithBaselineOnly(candidates: candidates, input: input)
        }

        let baseline = Self.baselineWeights(space: extractor.space)
        let evidence = household.totalEvidence
        let lambda = min(1.0, evidence / max(config.coldStartEvidence, .leastNormalMagnitude))
        let temperature = household.explorationTemperature(
            inflation: config.explorationInflation, decayEvidence: config.explorationDecayEvidence)
        let explore = input.context?.explore ?? true
        let meanWeights = household.mean()
        var meanBlended = [Double](repeating: 0, count: meanWeights.count)
        for i in 0..<meanBlended.count {
            meanBlended[i] = lambda * meanWeights[i] + (1 - lambda) * baseline[i]
        }

        var drawWeights = meanBlended
        if explore {
            // One Thompson draw per ranking: draw weights once, score every
            // candidate with them. Cold-start shrinkage scales the draw's
            // deviation by lambda (POLICY-3 in DESIGN.md).
            let normals = (0..<extractor.space.dimension).map { _ in rng.nextNormal() }
            let draw = household.thompsonDraw(standardNormals: normals, temperature: temperature)
            for i in 0..<drawWeights.count {
                drawWeights[i] += lambda * (draw[i] - meanWeights[i])
            }
        }

        var rows: [RankedRecipe] = []
        for (id, recipe) in candidates {
            let x = extractor.extract(recipe, catalog: catalog)
            let learnedMean = dot(meanBlended, x)
            let fit = clamp01(input.pantryFit[id] ?? 0.5)
            let popularity = clamp01(input.popularityOverride[id] ?? 0)

            let score = dot(drawWeights, x)

            var history: RecipeHistory?
            for eater in state.eaters.keys.sorted() {
                if let h = state.eaters[eater]?.recipeHistory[id] { history = h }
            }
            // The repeat nudge scales with the same evidence fraction as the
            // learned weights, so it can never override an explicit
            // correction while evidence is thin (POLICY-4 in DESIGN.md).
            let repeatBonus = lambda * Self.repeatBonus(history: history, now: now, config: config)
            let finalScore = score + config.pantryFitWeight * fit
                + config.popularityWeight * popularity + repeatBonus

            var contributions: [RankedRecipe.Contribution] = []
            for component in x.components {
                guard let key = extractor.space.key(at: component.index) else { continue }
                contributions.append(
                    .init(
                        feature: key, featureValue: component.value,
                        weight: meanBlended[component.index],
                        contribution: meanBlended[component.index] * component.value,
                        evidenceCount: household.evidence[component.index]))
            }
            contributions.sort { lhs, rhs in
                if lhs.contribution != rhs.contribution {
                    return abs(lhs.contribution) > abs(rhs.contribution)
                }
                return lhs.feature < rhs.feature
            }

            rows.append(
                .init(
                    recipe: id, score: finalScore, expectedUtility: learnedMean + repeatBonus,
                    pantryFit: fit, popularity: popularity, contributions: contributions))
        }

        return rows.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.recipe.rawValue < rhs.recipe.rawValue
        }
    }

    /// Baseline-only ranking (no eaters yet): the same blend terms, no
    /// learned part, no exploration (nothing learned to explore).
    private func rankWithBaselineOnly(
        candidates: [(RecipeID, CatalogRecipe)], input: RankInput
    ) -> [RankedRecipe] {
        let baseline = Self.baselineWeights(space: extractor.space)
        var rows: [RankedRecipe] = []
        for (id, recipe) in candidates {
            let x = extractor.extract(recipe, catalog: catalog)
            let learned = dot(baseline, x)
            let fit = clamp01(input.pantryFit[id] ?? 0.5)
            let popularity = clamp01(input.popularityOverride[id] ?? 0)
            var contributions: [RankedRecipe.Contribution] = []
            for component in x.components {
                guard let key = extractor.space.key(at: component.index) else { continue }
                contributions.append(
                    .init(
                        feature: key, featureValue: component.value,
                        weight: baseline[component.index],
                        contribution: baseline[component.index] * component.value,
                        evidenceCount: 0))
            }
            contributions.sort { abs($0.contribution) > abs($1.contribution) }
            rows.append(
                .init(
                    recipe: id,
                    score: learned + config.pantryFitWeight * fit
                        + config.popularityWeight * popularity,
                    expectedUtility: learned, pantryFit: fit, popularity: popularity,
                    contributions: contributions))
        }
        return rows.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.recipe.rawValue < rhs.recipe.rawValue
        }
    }

    /// Repeat affinity: log2(1 + decayed positive cooks) — a recipe cooked
    /// well recently resurfaces, with diminishing returns.
    static func repeatBonus(history: RecipeHistory?, now: Instant, config: TasteConfig) -> Double {
        guard let history, config.repeatAffinityWeight > 0 else { return 0 }
        var decayed = 0.0
        for cook in history.cooks {
            let positive = (cook.rating.map { $0.value >= 4 } ?? false) || cook.wouldMakeAgain == true
            guard positive else { continue }
            let ageDays = Double(cook.at.days(to: now))
            let decay = ageDays <= 0
                ? 1.0 : Foundation.pow(0.5, ageDays / config.repeatAffinityHalfLifeDays)
            decayed += decay
        }
        guard decayed > 0 else { return 0 }
        return config.repeatAffinityWeight * Foundation.log2(1 + decayed)
    }

    /// The rule-ranker baseline, mapped into the feature space: the same
    /// quick/easy/cheap lean as the app's current `RecipeScoring` heuristic.
    static func baselineWeights(space: FeatureSpace) -> [Double] {
        var weights = [Double](repeating: 0, count: space.dimension)
        func set(_ namespace: String, _ value: String, _ w: Double) {
            guard let index = space.index(of: FeatureKey(namespace: namespace, value: value)) else {
                return
            }
            weights[index] = w
        }
        for (value, w) in [("le15", 0.15), ("le30", 0.10), ("le60", 0.0), ("gt60", -0.10)] {
            set("time", value, w)
        }
        for (value, w) in [("simple", 0.12), ("moderate", 0.0), ("involved", -0.10)] {
            set("effort", value, w)
        }
        for (value, w) in [("low", 0.08), ("medium", 0.0), ("high", -0.05)] {
            set("cost", value, w)
        }
        return weights
    }
}

private func dot(_ weights: [Double], _ x: SparseVector) -> Double {
    var sum = 0.0
    for component in x.components where component.index < weights.count {
        sum += weights[component.index] * component.value
    }
    return sum
}

private func clamp01(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
}
