import Foundation
import FLTaste

/// The household simulator: replays a household's cooking life week by week
/// and emits exactly the events the real app would have recorded, plus the
/// hidden ground truth a scorer needs.
///
/// Determinism contract: the same (config, ranker) pair — the ranker being
/// itself seed-deterministic — produces byte-identical event and
/// ground-truth output on every run. Draw order is fixed and documented per
/// phase; every stream is a `SeedDeriver` child of the master seed, never
/// the system RNG or the wall clock.
public struct HouseholdSimulator {

    /// One completed run.
    public struct Run: Sendable {
        /// The emitted events, in emission order.
        public let events: [TasteEvent]
        /// The hidden truth for the same run.
        public let groundTruth: GroundTruth

        /// Events as canonical JSONL (one `EventCodec` object per line).
        public func eventsJSONL() -> String {
            events.map { CanonicalJSON.encode(EventCodec.encode($0)) }.joined(separator: "\n")
        }

        /// Ground truth as canonical JSON text.
        public func groundTruthJSON() -> String {
            groundTruth.jsonString()
        }
    }

    public let config: SimConfig
    public let catalog: RecipeCatalog
    public let ranker: any Ranker

    public init(config: SimConfig, catalog: RecipeCatalog, ranker: any Ranker) {
        self.config = config
        self.catalog = catalog
        self.ranker = ranker
    }

    // MARK: - Timeline constants

    private static let weekMillis: Int64 = 7 * 24 * 3_600_000
    private static let dayMillis: Int64 = 24 * 3_600_000
    /// Cooks happen in the evening; the exact hour is an assumption.
    private static let cookHourMillis: Int64 = 18 * 3_600_000

    // MARK: - Run

    public func run() -> Run {
        Mutables().execute(config: config, catalog: catalog, ranker: ranker)
    }

    /// Mutable run state; `run()` is pure on the outside.
    private final class Mutables {
        // Timeline constants (nested type cannot see the outer struct's
        // private statics via Self).
        static let weekMillis: Int64 = 7 * 24 * 3_600_000
        static let dayMillis: Int64 = 24 * 3_600_000
        static let cookHourMillis: Int64 = 18 * 3_600_000

        var events: [TasteEvent] = []
        var sessions: [GroundTruth.Session] = []
        var shiftRecords: [GroundTruth.ShiftRecord] = []
        var latentSnapshots: [GroundTruth.LatentSnapshot] = []
        var ratingNoiseDraws: [Double] = []
        var exposureCounts: [RecipeID: Int] = [:]
        var neverSuggest: Set<IngredientID> = []
        var recentCooks: [RecipeID] = []
        var raterBias: [String: Double] = [:]
        var missedCooks = 0
        var eventSequence = 0
        var sessionIndex = 0

        func execute(config: SimConfig, catalog: RecipeCatalog, ranker: any Ranker) -> Run {
            try! config.validate()
            let extractor = FeatureExtractor(catalog: catalog)
            let householdInitial = HouseholdFactory.generate(config: config, catalog: catalog)
            var household = householdInitial
            for eater in household.eaters {
                let index = Int(eater.id.rawValue.dropFirst()) ?? 0
                var biasRng = SeededRNG(
                    seed: SeedDeriver.child(config.seed, "rater-bias", index))
                raterBias[eater.id.rawValue] = biasRng.nextNormal() * 0.25
            }

            var world = World(config: config, catalog: catalog)
            var shopping = SeededRNG(seed: SeedDeriver.child(config.seed, "shopping", 0))
            var session = SeededRNG(seed: SeedDeriver.child(config.seed, "session", 0))
            var rating = SeededRNG(seed: SeedDeriver.child(config.seed, "rating", 0))

            for week in 0..<config.weeks {
                let weekStartMillis = config.startMillis + Int64(week) * Mutables.weekMillis
                world.startWeek(week: week, shelfLifeWeeks: config.pantryShelfLifeWeeks)

                // 1. Shifts (at week start) and slow drift.
                let applied = Dynamics.applyShifts(
                    config.shifts, week: week, atMillis: weekStartMillis, world: &world,
                    household: &household)
                for shift in applied {
                    shiftRecords.append(Self.shiftRecord(shift))
                    if case .diet(let eaterIndex, let diet, _) = shift.spec {
                        // The eater declares the diet in the app — an explicit
                        // profile edit, unlike the environmental shifts.
                        emit(
                            at: shift.atMillis, eater: household.eaters[eaterIndex].id,
                            exposure: nil,
                            kind: .profileEdit(
                                .setRestriction(
                                    Restriction(
                                        kind: .diet, target: diet.rawValue, source: "shift"))))
                    }
                }
                for index in household.eaters.indices {
                    Dynamics.applyDrift(
                        &household.eaters[index].latent, angle: config.driftPerWeek,
                        eaterIndex: index, masterSeed: config.seed)
                }
                latentSnapshots.append(
                    GroundTruth.LatentSnapshot(
                        week: week, atMillis: weekStartMillis,
                        latents: Dictionary(
                            uniqueKeysWithValues: household.eaters.map {
                                ($0.id.rawValue, $0.latent)
                            })))

                // 2. Shopping day: plan meals by taste, buy within budget.
                let filter = FeasibilityFilter(
                    unionRestrictions: household.restrictionUnion,
                    neverSuggest: neverSuggest, capabilityNeedles: world.capabilityNeedles)
                let legal = filter.legalRecipes(catalog: catalog)
                let legalUtilities = Self.utilities(
                    for: legal, household: household, extractor: extractor, catalog: catalog)
                let plans = Self.planMeals(
                    legal: legal, utilities: legalUtilities, count: config.shopMealsPerWeek,
                    temperature: config.choiceTemperature, rng: &shopping)
                _ = world.shop(week: week, plans: plans)

                // 3. Cook sessions. Poisson(cooksPerWeek) by Knuth inversion.
                let cookCount = Self.poisson(mean: config.cooksPerWeek, rng: &session)
                let cookDays = Self.shuffledDays(count: cookCount, rng: &session)
                for day in cookDays {
                    let atMillis =
                        weekStartMillis + Int64(day) * Mutables.dayMillis
                        + Mutables.cookHourMillis
                    runSession(
                        week: week, atMillis: atMillis, household: &household, world: &world,
                        filter: filter, extractor: extractor, ranker: ranker, session: &session,
                        rating: &rating, config: config)
                }
            }

            let groundTruth = GroundTruth(
                rankerId: ranker.id,
                seed: config.seed,
                weeks: config.weeks,
                householdInitial: householdInitial,
                raterBias: raterBias,
                shifts: shiftRecords,
                latentsOverTime: latentSnapshots,
                sessions: sessions,
                ratingNoiseDraws: ratingNoiseDraws,
                missedCooks: missedCooks,
                eventCount: events.count
            )
            return Run(events: events, groundTruth: groundTruth)
        }

        // MARK: - One cook session

        private func runSession(
            week: Int, atMillis: Int64, household: inout Household, world: inout World,
            filter: FeasibilityFilter, extractor: FeatureExtractor, ranker: any Ranker,
            session: inout SeededRNG,
            rating: inout SeededRNG, config: SimConfig
        ) {
            let cookIndex = sessionIndex
            sessionIndex += 1
            let feasible = filter.feasibleRecipes(catalog: world.catalog, pantry: world.pantry)
            let utilities = Self.utilities(
                for: feasible, household: household, extractor: extractor,
                catalog: world.catalog)
            let availability = Self.availabilityFactors(feasible: feasible, pantry: world.pantry)
            let actorIndex = cookIndex % max(1, household.eaters.count)
            let actor = household.eaters[actorIndex].id
            let actorBias = raterBias[actor.rawValue] ?? 0

            var sessionRecord = GroundTruth.Session(
                week: week, atMillis: atMillis, cookIndex: cookIndex, actorId: actor.rawValue,
                feasibleIds: feasible.map { $0.id.rawValue }, slateIds: [], choiceId: nil,
                outcome: .nothingFeasible, trueRanking: Self.ranked(feasible, utilities),
                utilities: Dictionary(
                    uniqueKeysWithValues: zip(feasible.map { $0.id.rawValue }, utilities)),
                choiceProbabilities: [:], availability: availability, rating: nil, skip: nil,
                substitution: nil, neverSuggestIngredient: nil)

            guard !feasible.isEmpty else {
                missedCooks += 1
                sessions.append(sessionRecord)
                return
            }

            let attended = session.nextUniform() < config.attentionProbability
            var slateRecipes: [CatalogRecipe] = []
            var probabilities: [Double] = []

            if attended {
                let candidates = zip(feasible, utilities).map { recipe, utility in
                    Candidate(
                        recipe: recipe, householdUtility: utility,
                        availability: availability[recipe.id.rawValue] ?? 1,
                        exposureCount: exposureCounts[recipe.id] ?? 0)
                }
                let rankedIds = ranker.rank(
                    candidates,
                    context: RankingContext(
                        week: week, slateSize: config.slateSize, sessionIndex: cookIndex))
                // Defensive contract filter: dedupe, keep known candidates,
                // cap at slateSize.
                var seen: Set<RecipeID> = []
                slateRecipes = rankedIds.compactMap { id -> CatalogRecipe? in
                    guard !seen.contains(id) else { return nil }
                    seen.insert(id)
                    return world.catalog.recipes[id]
                }.prefix(config.slateSize).map { $0 }
                if slateRecipes.isEmpty {
                    // A ranker returned nothing usable: fall back to the
                    // feasible order so the household still sees a surface.
                    slateRecipes = Array(feasible.prefix(config.slateSize))
                }
                let slateCandidates = slateRecipes.map { recipe in
                    candidates.first { $0.recipe.id == recipe.id }!
                }
                probabilities = ChoiceModel.probabilities(slate: slateCandidates, config: config)
                sessionRecord.choiceProbabilities = Dictionary(
                    uniqueKeysWithValues: zip(
                        slateCandidates.map { $0.recipe.id.rawValue }, probabilities))
                sessionRecord.slateIds = slateRecipes.map { $0.id.rawValue }
                for recipe in slateRecipes {
                    exposureCounts[recipe.id, default: 0] += 1
                    emit(
                        at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                        kind: .viewed(recipe: recipe.id))
                }
            } else {
                // Unattended: habit cook — the most recent cooked recipe that
                // is still feasible, else the best-utility feasible one. No
                // slate, no exposure events.
                sessionRecord.outcome = .unattended
                let habit =
                    recentCooks.compactMap { id in feasible.first { $0.id == id } }.first
                    ?? Self.bestUtility(feasible, utilities)
                slateRecipes = [habit]
            }

            // Skip session: attended, slate shown, but no cook happened.
            if attended, !slateRecipes.isEmpty,
                session.nextUniform() < config.skipSessionProbability
            {
                let reason = Self.skipReason(rng: &session)
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .skipped(recipe: slateRecipes[0].id, reason: reason))
                sessionRecord.outcome = .skippedSession
                sessionRecord.skip = GroundTruth.SkipRecord(
                    recipeId: slateRecipes[0].id.rawValue, reason: reason.rawValue)
                sessions.append(sessionRecord)
                return
            }

            // Choose.
            let chosen: CatalogRecipe
            if attended, !slateRecipes.isEmpty {
                let pick = ChoiceModel.sample(probabilities, &session)
                chosen = slateRecipes[pick]
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .opened(recipe: chosen.id))
                if session.nextUniform() < config.extraOpenProbability, slateRecipes.count > 1 {
                    // Comparison browsing: open one more slate item.
                    let other = (pick + 1) % slateRecipes.count
                    emit(
                        at: atMillis, eater: actor,
                        exposure: exposureContext(feasible, slateRecipes),
                        kind: .viewed(recipe: slateRecipes[other].id))
                    emit(
                        at: atMillis, eater: actor,
                        exposure: exposureContext(feasible, slateRecipes),
                        kind: .opened(recipe: slateRecipes[other].id))
                }
            } else {
                chosen = slateRecipes[0]
                emit(at: atMillis, eater: actor, exposure: nil, kind: .opened(recipe: chosen.id))
            }
            sessionRecord.choiceId = chosen.id.rawValue
            let chosenIndex = feasible.firstIndex { $0.id == chosen.id } ?? 0
            let chosenUtility = utilities[chosenIndex]

            // Substitution: swap the least-liked required ingredient. The
            // substitute comes from the pantry when one is available.
            if session.nextUniform() < config.substitutionProbability,
                chosen.requiredIngredients.count > 1
            {
                let from = Self.leastLiked(
                    chosen.requiredIngredients, extractor: extractor,
                    latent: householdMeanLatent(household))
                let pantryIds = world.pantry.gramsByIngredient()
                    .filter { $0.key != from && $0.value > 0 }
                    .map { $0.key }.sorted { $0.rawValue < $1.rawValue }
                let to: IngredientID? =
                    pantryIds.isEmpty ? nil : pantryIds[Int(session.nextUniform() * Double(pantryIds.count))]
                let preferred = session.nextUniform() < config.preferredSubstitutionProbability
                let mode: SubstitutionMode = preferred ? .preferred : .necessary
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .substituted(recipe: chosen.id, from: from, to: to, mode: mode))
                sessionRecord.substitution = GroundTruth.SubstitutionRecord(
                    recipeId: chosen.id.rawValue, from: from.rawValue, to: to?.rawValue,
                    mode: mode.rawValue)
            }

            // Rating path: sparse, noisy, biased by the rater.
            var ratingDraw: GroundTruth.RatingDraw?
            if session.nextUniform() < config.ratingProbability {
                let noise = rating.nextNormal() * config.ratingNoiseSigma
                ratingNoiseDraws.append(noise)
                let mean = 2.5 + config.ratingSlope * chosenUtility + actorBias
                let stars = min(5, max(1, Int((mean + noise).rounded())))
                var wouldMakeAgain: Bool?
                if session.nextUniform() < config.wouldMakeAgainProbability {
                    let logit =
                        config.wouldMakeAgainSlope
                        * (chosenUtility - config.wouldMakeAgainMidpoint)
                    wouldMakeAgain = rating.nextUniform() < 1 / (1 + exp(-logit))
                }
                ratingDraw = GroundTruth.RatingDraw(
                    latentMean: chosenUtility, raterBias: actorBias, noise: noise, stars: stars,
                    wouldMakeAgain: wouldMakeAgain)
            }
            sessionRecord.rating = ratingDraw

            emit(
                at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                kind: .cooked(
                    recipe: chosen.id,
                    rating: ratingDraw.flatMap { Rating($0.stars) },
                    wouldMakeAgain: ratingDraw?.wouldMakeAgain))

            // Saved: only when the cook was loved.
            if chosenUtility >= config.saveUtilityThreshold,
                session.nextUniform() < config.saveProbability
            {
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .saved(recipe: chosen.id))
            }

            // Double servings for leftovers.
            if session.nextUniform() < config.doubleServingsProbability {
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .editedServings(
                        recipe: chosen.id, from: chosen.servings, to: chosen.servings * 2))
            }

            // LeChef feedback: heuristic, documented in SIM-ASSUMPTIONS.md.
            if session.nextUniform() < config.leChefFeedbackProbability {
                let type: LeChefFeedback.FeedbackType
                if chosenUtility < 0 {
                    type = .tooBland
                } else if chosen.timeMinutes > 45 {
                    type = .tookTooLong
                } else if session.nextUniform() < 0.5 {
                    type = .portionWrong
                } else {
                    type = .other
                }
                emit(
                    at: atMillis, eater: actor, exposure: exposureContext(feasible, slateRecipes),
                    kind: .leChefFeedback(
                        recipe: chosen.id, feedback: LeChefFeedback(type: type, note: nil)))
            }

            // Never-suggest: a bad cook can harden into an explicit edit.
            if chosenUtility <= config.neverSuggestUtility,
                session.nextUniform() < config.neverSuggestProbability
            {
                let ingredient = Self.leastLiked(
                    chosen.requiredIngredients, extractor: extractor,
                    latent: householdMeanLatent(household))
                if !neverSuggest.contains(ingredient) {
                    neverSuggest.insert(ingredient)
                    emit(
                        at: atMillis, eater: actor,
                        exposure: exposureContext(feasible, slateRecipes),
                        kind: .profileEdit(.setNeverSuggest(ingredient: ingredient)))
                    sessionRecord.neverSuggestIngredient = ingredient.rawValue
                }
            }

            if attended { sessionRecord.outcome = .cooked }
            sessions.append(sessionRecord)
            recentCooks.removeAll { $0 == chosen.id }
            recentCooks.insert(chosen.id, at: 0)
            world.consume(chosen)
        }

        // MARK: - Emission helpers

        private func emit(
            at millis: Int64, eater: EaterID?, exposure: ExposureContext?, kind: EventKind
        ) {
            eventSequence += 1
            let id = EventID(String(format: "sim-%06d", eventSequence))!
            events.append(
                TasteEvent(
                    id: id, at: Instant(millisecondsSinceEpoch: millis)!, eater: eater,
                    exposure: exposure, kind: kind))
        }

        private func exposureContext(
            _ feasible: [CatalogRecipe], _ slate: [CatalogRecipe]
        ) -> ExposureContext? {
            try? ExposureContext(
                feasibleCandidates: feasible.count, shownCandidates: slate.count)
        }

        private func householdMeanLatent(_ household: Household) -> [Double] {
            guard let first = household.eaters.first else { return [] }
            var mean = first.latent
            for eater in household.eaters.dropFirst() {
                for (i, v) in eater.latent.enumerated() { mean[i] += v }
            }
            return mean.map { $0 / Double(max(1, household.eaters.count)) }
        }

        private static func shiftRecord(_ applied: Dynamics.AppliedShift) -> GroundTruth.ShiftRecord {
            let kind: String
            let detail: [String: String]
            switch applied.spec {
            case .diet(_, let diet, _):
                kind = "diet"
                detail = ["diet": diet.rawValue]
            case .budgetChange(let factor, _):
                kind = "budgetChange"
                detail = ["factor": String(format: "%.3f", factor)]
            case .lostCapability(let needle, _):
                kind = "lostCapability"
                detail = ["needle": needle]
            }
            return GroundTruth.ShiftRecord(
                week: applied.spec.week, atMillis: applied.atMillis, kind: kind, detail: detail)
        }

        // MARK: - Pure helpers

        static func utilities(
            for recipes: [CatalogRecipe], household: Household, extractor: FeatureExtractor,
            catalog: RecipeCatalog
        ) -> [Double] {
            recipes.map { recipe in
                let features = extractor.extract(recipe, catalog: catalog)
                return household.eaters.map { features.dot($0.latent) }.reduce(0, +)
                    / Double(max(1, household.eaters.count))
            }
        }

        static func availabilityFactors(
            feasible: [CatalogRecipe], pantry: Pantry
        ) -> [String: Double] {
            var factors: [String: Double] = [:]
            for recipe in feasible {
                var factor = Double.infinity
                for use in recipe.requiredIngredients {
                    guard use.grams > 0 else { continue }
                    factor = min(factor, pantry.grams(of: use.id) / use.grams)
                }
                factors[recipe.id.rawValue] = min(2.0, factor.isFinite ? factor : 1.0)
            }
            return factors
        }

        static func ranked(_ recipes: [CatalogRecipe], _ utilities: [Double]) -> [String] {
            let pairs = zip(recipes.map { $0.id.rawValue }, utilities)
            return pairs.sorted {
                $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
            }.map { $0.0 }
        }

        /// Poisson(mean) by Knuth inversion — deterministic per stream.
        static func poisson(mean: Double, rng: inout SeededRNG) -> Int {
            let limit = exp(-mean)
            var k = 0
            var p = 1.0
            repeat {
                k += 1
                p *= rng.nextUniform()
            } while p > limit
            return k - 1
        }

        /// `count` distinct cook days in 0...6, drawn by shuffle then sorted.
        static func shuffledDays(count: Int, rng: inout SeededRNG) -> [Int] {
            var days = Array(0...6)
            for i in stride(from: days.count - 1, to: 0, by: -1) {
                let j = Int(rng.nextUniform() * Double(i + 1))
                days.swapAt(i, min(j, i))
            }
            return Array(days.prefix(min(count, days.count))).sorted()
        }

        /// Typed skip reasons: mostly time and appetite, occasionally stock.
        static func skipReason(rng: inout SeededRNG) -> SkipReason {
            let draw = rng.nextUniform()
            if draw < 0.4 { return .outOfTime }
            if draw < 0.8 { return .changedMind }
            return .missingIngredients
        }

        /// The required ingredient the household's mean taste likes least
        /// (ties by id). Unrated ingredients score 0.
        static func leastLiked(
            _ uses: [CatalogRecipe.IngredientUse], extractor: FeatureExtractor, latent: [Double]
        ) -> IngredientID {
            func weight(_ id: IngredientID) -> Double {
                guard
                    let index = extractor.space.index(
                        of: FeatureKey(namespace: "ingredient", value: id.rawValue))
                else { return 0 }
                return latent[index]
            }
            return uses.min {
                weight($0.id) == weight($1.id)
                    ? $0.id.rawValue < $1.id.rawValue
                    : weight($0.id) < weight($1.id)
            }?.id ?? uses[0].id
        }

        static func bestUtility(_ recipes: [CatalogRecipe], _ utilities: [Double]) -> CatalogRecipe {
            var best = 0
            for i in recipes.indices where utilities[i] > utilities[best] { best = i }
            return recipes[best]
        }

        /// Weighted sample without replacement, weight ∝ exp(u/T).
        static func planMeals(
            legal: [CatalogRecipe], utilities: [Double], count: Int, temperature: Double,
            rng: inout SeededRNG
        ) -> [CatalogRecipe] {
            var pool = Array(zip(legal, utilities))
            var plans: [CatalogRecipe] = []
            for _ in 0..<min(count, pool.count) {
                let ceiling = pool.map { $0.1 }.max() ?? 0
                let weights = pool.map { exp(($0.1 - ceiling) / temperature) }
                let total = weights.reduce(0, +)
                var draw = rng.nextUniform() * total
                var picked = 0
                for (i, w) in weights.enumerated() {
                    draw -= w
                    if draw <= 0 { picked = i; break }
                }
                plans.append(pool[picked].0)
                pool.remove(at: picked)
            }
            return plans
        }
    }
}
