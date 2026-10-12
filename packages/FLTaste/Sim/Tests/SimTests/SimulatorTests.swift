import Foundation
import XCTest
@testable import FLTasteSim
import FLTaste

/// M2: the weekly loop — event emission, hidden ground truth, determinism,
/// and the contract smoke test against Part 1's real `TasteEngine`.
final class SimulatorTests: XCTestCase {

    // MARK: - Harness

    private func run(
        seed: UInt64 = 7, weeks: Int = 8, householdSize: Int = 2,
        shifts: [ShiftSpec] = [], ranker: any Ranker = RandomRanker(seed: 42),
        mutate: (inout SimConfig) -> Void = { _ in }
    ) -> HouseholdSimulator.Run {
        var config = SimFixtures.config(
            seed: seed, weeks: weeks, householdSize: householdSize, shifts: shifts)
        mutate(&config)
        let simulator = HouseholdSimulator(
            config: config, catalog: SimFixtures.catalog(), ranker: ranker)
        return simulator.run()
    }

    private func isViewed(_ event: TasteEvent) -> Bool {
        if case .viewed = event.kind { return true }
        return false
    }

    // MARK: - Contract smoke test (mandatory)

    /// The simulator's event stream must be accepted, unchanged, by a real
    /// `TasteEngine` from the path dependency: full ingest, idempotent
    /// replay, order-independent fold, and snapshot round-trip.
    func testContractSmokeTasteEngineIngestsSimulatedEvents() throws {
        let output = run(seed: 7, weeks: 8)
        XCTAssertFalse(output.events.isEmpty, "an 8-week run should emit events")

        var engine = TasteEngine(catalog: SimFixtures.catalog())
        engine.ingest(output.events)
        XCTAssertEqual(engine.eventCount, output.events.count, "engine accepted every event")

        // Idempotency: replaying the whole stream is a no-op.
        engine.ingest(output.events)
        XCTAssertEqual(engine.eventCount, output.events.count)

        // Order-independence: a fresh engine fed the reversed stream folds
        // to the identical canonical state.
        var reversedEngine = TasteEngine(catalog: SimFixtures.catalog())
        reversedEngine.ingest(output.events.reversed())
        XCTAssertEqual(try reversedEngine.snapshotJSON(), try engine.snapshotJSON())

        // Snapshot round-trip: canonical bytes restore to the same bytes.
        let snapshot = try engine.snapshotJSON()
        let restored = try TasteEngine(snapshotJSON: snapshot, catalog: SimFixtures.catalog())
        XCTAssertEqual(try restored.snapshotJSON(), snapshot)
        XCTAssertEqual(restored.eventCount, output.events.count)
    }

    /// The same smoke contract against the real 166-recipe app corpus.
    func testContractSmokeAgainstRealCorpus() throws {
        guard let path = SimFixtures.repoDataJSONPath() else {
            throw XCTSkip("repo checkout with apps/ios/Resources/data.json not found")
        }
        let json = try String(contentsOfFile: path, encoding: .utf8)
        let catalog = try CatalogLoader.load(dataJSON: json)

        var config = SimConfig()
        config.seed = 20
        config.weeks = 12
        let output = HouseholdSimulator(
            config: config, catalog: catalog, ranker: RandomRanker(seed: 1)
        ).run()
        XCTAssertGreaterThan(output.events.count, 50, "12 weeks on the real corpus cooks plenty")

        var engine = TasteEngine(catalog: catalog)
        engine.ingest(output.events)
        XCTAssertEqual(engine.eventCount, output.events.count)
        engine.ingest(output.events)
        XCTAssertEqual(engine.eventCount, output.events.count)
        let snapshot = try engine.snapshotJSON()
        let restored = try TasteEngine(snapshotJSON: snapshot, catalog: catalog)
        XCTAssertEqual(try restored.snapshotJSON(), snapshot)
    }

    // MARK: - Determinism

    /// Same seed + config + ranker ⇒ byte-identical event JSONL and
    /// ground-truth JSON; a different seed differs.
    func testDeterminismSameConfigByteIdentical() {
        let first = run(seed: 99, weeks: 10)
        let second = run(seed: 99, weeks: 10)
        XCTAssertEqual(first.eventsJSONL(), second.eventsJSONL())
        XCTAssertEqual(first.groundTruthJSON(), second.groundTruthJSON())

        let other = run(seed: 100, weeks: 10)
        XCTAssertNotEqual(first.eventsJSONL(), other.eventsJSONL())
        XCTAssertNotEqual(first.groundTruthJSON(), other.groundTruthJSON())
    }

    // MARK: - Loop invariants

    /// Slates are subsets of the feasible set, capped at slateSize, with
    /// matching choice probabilities; every slate is mirrored by viewed
    /// events carrying an exposure record.
    func testSlateIsSubsetOfFeasibleAndExposureIsLogged() throws {
        let output = run(weeks: 8)
        var attendedSessions = 0
        for session in output.groundTruth.sessions where !session.slateIds.isEmpty {
            attendedSessions += 1
            XCTAssertLessThanOrEqual(session.slateIds.count, 6, "slate cap")
            XCTAssertTrue(
                Set(session.slateIds).isSubset(of: Set(session.feasibleIds)),
                "slate must come from the feasible set")
            XCTAssertEqual(
                Set(session.choiceProbabilities.keys), Set(session.slateIds),
                "probabilities cover exactly the slate")
        }
        XCTAssertGreaterThan(attendedSessions, 0, "the default config attends sometimes")

        let viewed = output.events.filter(isViewed)
        XCTAssertGreaterThanOrEqual(viewed.count, attendedSessions)
        for event in viewed {
            let exposure = try XCTUnwrap(event.exposure, "viewed events carry exposure")
            XCTAssertGreaterThan(exposure.feasibleCandidates, 0)
        }
    }

    /// Choice probabilities are a distribution.
    func testChoiceProbabilitiesSumToOne() {
        let output = run(weeks: 8)
        var checked = 0
        for session in output.groundTruth.sessions where !session.choiceProbabilities.isEmpty {
            let total = session.choiceProbabilities.values.reduce(0, +)
            XCTAssertEqual(total, 1.0, accuracy: 1e-6)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// Every cook-emitting session (attended and habit) emits exactly one
    /// cooked event; skipped sessions emit a typed skip and never a cooked
    /// event; unattended sessions never carry a slate.
    func testCookAndSkipEventMirroring() throws {
        let output = run(weeks: 10)
        var cookedKinds = 0
        var skipKinds = 0
        for event in output.events {
            if case .cooked = event.kind { cookedKinds += 1 }
            if case .skipped = event.kind { skipKinds += 1 }
        }
        let cookedSessions = output.groundTruth.sessions.filter {
            $0.outcome == .cooked || $0.outcome == .unattended
        }
        let skippedSessions = output.groundTruth.sessions.filter { $0.outcome == .skippedSession }
        XCTAssertEqual(cookedKinds, cookedSessions.count)
        XCTAssertEqual(skipKinds, skippedSessions.count)
        for session in skippedSessions {
            XCTAssertNil(session.choiceId, "a skipped session cooks nothing")
            XCTAssertNotNil(session.skip)
        }
        for session in output.groundTruth.sessions where session.outcome == .unattended {
            XCTAssertTrue(session.slateIds.isEmpty, "habit cooks see no slate")
        }
        for session in cookedSessions {
            let choice = try XCTUnwrap(session.choiceId)
            XCTAssertTrue(
                session.slateIds.isEmpty || session.slateIds.contains(choice)
                    || session.outcome == .unattended)
        }
    }

    // MARK: - Distribution sanity

    /// Loose sanity: high-latent-utility cooks rate clearly better than
    /// low-utility cooks. With `ratingProbability` forced to 1, a 24-week
    /// run yields enough ratings for even a loose check to be meaningful.
    func testRatingsTrackLatentTaste() {
        let output = run(seed: 11, weeks: 24) { $0.ratingProbability = 1.0 }
        let rated = output.groundTruth.sessions.compactMap { session -> (Double, Int)? in
            guard let rating = session.rating else { return nil }
            return (rating.latentMean, rating.stars)
        }
        XCTAssertGreaterThanOrEqual(
            rated.count, 30, "24 weeks with forced rating should produce enough data")

        let sorted = rated.sorted { $0.0 < $1.0 }
        let bottom = sorted.prefix(rated.count / 3)
        let top = sorted.suffix(rated.count / 3)
        let bottomMean = bottom.map { Double($0.1) }.reduce(0, +) / Double(bottom.count)
        let topMean = top.map { Double($0.1) }.reduce(0, +) / Double(top.count)
        XCTAssertGreaterThan(
            topMean, bottomMean,
            "top-utility cooks must out-rate bottom-utility cooks on average")
    }

    /// The recorded rating anatomy is complete: a scorer can reproduce every
    /// star value from ground truth alone (latent mean, rater bias, noise).
    func testRatingAnatomyReproducesStars() throws {
        var config = SimFixtures.config(seed: 3, weeks: 12)
        config.ratingProbability = 1.0
        let output = HouseholdSimulator(
            config: config, catalog: SimFixtures.catalog(), ranker: RandomRanker(seed: 42)
        ).run()

        let rated = output.groundTruth.sessions.filter { $0.rating != nil }
        XCTAssertEqual(rated.count, output.groundTruth.ratingNoiseDraws.count)
        for (index, session) in rated.enumerated() {
            let rating = try XCTUnwrap(session.rating)
            let bias = try XCTUnwrap(output.groundTruth.raterBias[session.actorId])
            let noise = output.groundTruth.ratingNoiseDraws[index]
            let mean = 2.5 + config.ratingSlope * rating.latentMean + bias + noise
            let expected = min(5, max(1, Int(mean.rounded())))
            XCTAssertEqual(rating.stars, expected, "session \(session.cookIndex) stars")
        }
    }

    // MARK: - Dynamics

    /// "Went vegetarian" mid-history: the shift is recorded, the app sees an
    /// explicit restriction edit, and every feasible set from the shift week
    /// on is vegetarian-only — while meat recipes were feasible before.
    func testVegetarianShiftRemovesNonVegetarianFeasibility() throws {
        let output = run(
            seed: 5, weeks: 6,
            shifts: [ShiftSpec.diet(eaterIndex: 0, diet: .vegetarian, week: 3)]
        ) { config in
            // No generated restrictions: the injected shift is the only diet
            // in play, so the pre/post contrast is the shift's doing.
            config.restrictionProbability = 0
        }
        let catalog = SimFixtures.catalog()

        XCTAssertEqual(output.groundTruth.shifts.count, 1)
        XCTAssertEqual(output.groundTruth.shifts[0].week, 3)
        XCTAssertEqual(output.groundTruth.shifts[0].kind, "diet")

        XCTAssertTrue(
            output.events.contains { event in
                if case .profileEdit(.setRestriction(let restriction)) = event.kind {
                    return restriction.kind == .diet && restriction.target == "vegetarian"
                }
                return false
            }, "the diet change is an explicit profile edit in the stream")

        let postShift = output.groundTruth.sessions.filter { $0.week >= 3 }.flatMap { $0.feasibleIds }
        XCTAssertFalse(postShift.isEmpty)
        for id in postShift {
            let recipe = try XCTUnwrap(catalog.recipes[RecipeID(id)!])
            XCTAssertTrue(recipe.hasTag(.vegetarian), "\(id) feasible after shift must be vegetarian")
        }

        let preShift = output.groundTruth.sessions.filter { $0.week < 3 }.flatMap { $0.feasibleIds }
        XCTAssertTrue(
            preShift.contains { id in
                !(catalog.recipes[RecipeID(id)!]!.hasTag(.vegetarian))
            }, "meat recipes were feasible before the shift (the shift matters)")
    }

    /// Budget-starved households never cook: no events at all, every
    /// scheduled session is `nothingFeasible`, and the misses are counted.
    func testBudgetStarvedHouseholdCooksNothing() {
        let output = run(weeks: 6) { $0.weeklyBudget = 0.001 }
        XCTAssertFalse(output.groundTruth.sessions.isEmpty)
        XCTAssertTrue(output.events.isEmpty, "no pantry, no app activity")
        XCTAssertTrue(
            output.groundTruth.sessions.allSatisfy { $0.outcome == .nothingFeasible })
        XCTAssertGreaterThan(output.groundTruth.missedCooks, 0)
    }

    /// Taste drift moves the latent vector slowly: over a long run the
    /// weekly snapshots drift a little each week but never jump.
    func testDriftIsSlowAndBounded() {
        let output = run(seed: 13, weeks: 16)
        let snapshots = output.groundTruth.latentsOverTime
        XCTAssertEqual(snapshots.count, 16)
        let eater = snapshots[0].latents.keys.sorted().first!
        var last = snapshots[0].latents[eater]!
        for snapshot in snapshots.dropFirst() {
            let current = snapshot.latents[eater]!
            let stepDistance = zip(current, last).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                .squareRoot()
            XCTAssertLessThan(stepDistance, 0.5, "per-week drift is small")
            XCTAssertGreaterThan(stepDistance, 0, "drift actually moves the vector")
            last = current
        }
    }

    // MARK: - Ranker contracts

    /// Reference rankers: deterministic, permutations of the candidates,
    /// popularity order actually descending. They receive only the seam's
    /// observable projection — building their input needs no household at
    /// all, because `RankerInput` takes no latent data.
    func testReferenceRankersHonorContract() throws {
        let catalog = SimFixtures.catalog()
        let legal = FeasibilityFilter(unionRestrictions: []).legalRecipes(catalog: catalog)
        XCTAssertGreaterThanOrEqual(legal.count, 8)
        let candidates = RankerInput.candidates(
            for: legal, availability: [:], exposureCounts: [:])
        let context = RankingContext(
            week: 0, slateSize: 6, sessionIndex: 0, history: [], restrictions: [])

        let random = RandomRanker(seed: 1234)
        let first = random.rank(candidates, context: context)
        let second = random.rank(candidates, context: context)
        XCTAssertEqual(first, second, "same seed + context replays exactly")
        XCTAssertEqual(Set(first), Set(candidates.map { $0.id }), "a permutation")
        XCTAssertEqual(first.count, candidates.count)

        let popularity = PopularityProxyRanker()
        let order = popularity.rank(candidates, context: context)
        XCTAssertEqual(Set(order), Set(candidates.map { $0.id }))
        for (a, b) in zip(order, order.dropFirst()) {
            let scoreA = PopularityProxyRanker.popularityScore(
                candidates.first { $0.id == a }!)
            let scoreB = PopularityProxyRanker.popularityScore(
                candidates.first { $0.id == b }!)
            XCTAssertTrue(
                scoreA > scoreB || (scoreA == scoreB && a.rawValue < b.rawValue),
                "popularity order descending, ties by id")
        }
    }

    /// The default choice temperature is taste-driven but not deterministic:
    /// among attentive cooked sessions the slate's best-true-utility item is
    /// picked well above the uniform-share baseline, yet far below always.
    /// Pins the behavioural claim in SIM-ASSUMPTIONS.md §4.
    func testChoiceIsTasteDrivenAtDefaultTemperature() {
        let output = run(seed: 17, weeks: 13)
        var topUtilityPicks = 0
        var sessions = 0
        for session in output.groundTruth.sessions
        where session.outcome == .cooked && !session.slateIds.isEmpty {
            sessions += 1
            let topSlate =
                session.slateIds.max {
                    (session.utilities[$0] ?? -.infinity) < (session.utilities[$1] ?? -.infinity)
                }!
            if topSlate == session.choiceId { topUtilityPicks += 1 }
        }
        XCTAssertGreaterThanOrEqual(sessions, 15, "13 weeks must yield enough cooks")
        let share = Double(topUtilityPicks) / Double(sessions)
        XCTAssertGreaterThan(share, 0.4, "taste dominates at the default temperature")
        XCTAssertLessThan(share, 0.9, "the pick is not deterministic")
    }

    /// A ranker that returns unknown ids is filtered defensively; the
    /// household still sees a slate drawn from the feasible set.
    func testUnknownRankerOutputIsFilteredDefensively() {
        struct Broken: Ranker {
            let id = "broken"
            func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
                [RecipeID("r_ghost")!, RecipeID("r_ghost")!] + candidates.map { $0.id }
            }
        }
        let output = run(weeks: 4, ranker: Broken())
        for session in output.groundTruth.sessions where !session.slateIds.isEmpty {
            XCTAssertTrue(Set(session.slateIds).isSubset(of: Set(session.feasibleIds)))
            XCTAssertLessThanOrEqual(session.slateIds.count, 6)
        }
    }

    /// The contract filter also drops a KNOWN id that is not feasible this
    /// session — the review's crash case: the old filter accepted any
    /// catalog id and force-unwrapped the candidate.
    func testSlateFilterDropsKnownButInfeasibleIds() {
        let catalog = SimFixtures.catalog()
        let all = Array(catalog.recipes.values).sorted { $0.id.rawValue < $1.id.rawValue }
        let feasible = Array(all.prefix(5))
        let infeasibleButKnown = all[7].id
        let ranked = [
            RecipeID("r_ghost")!, infeasibleButKnown, feasible[1].id, feasible[1].id,
            feasible[3].id, infeasibleButKnown,
        ]
        XCTAssertEqual(
            HouseholdSimulator.slate(from: ranked, feasible: feasible, cap: 10)
                .map { $0.id }, [feasible[1].id, feasible[3].id])
        XCTAssertEqual(
            HouseholdSimulator.slate(from: ranked, feasible: feasible, cap: 1)
                .map { $0.id }, [feasible[1].id])
    }

    // MARK: - Hidden-truth boundary (review blocker 1)

    /// Even a ranker that reflects over EVERYTHING it receives finds no
    /// latent data: no numeric leaf of the candidates or context matches
    /// any true session utility or any latent component of the run.
    func testRankerSeesNoLatentDataEvenUnderReflection() throws {
        // Single-threaded run; the spy accumulates dumps across calls.
        final class Spy: Ranker, @unchecked Sendable {
            let id = "spy"
            var dumps: [[Double]] = []
            func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
                var numbers: [Double] = []
                var strings: [String] = []
                ReflectionDump.walk(candidates, path: "", into: &numbers, strings: &strings)
                ReflectionDump.walk(context, path: "", into: &numbers, strings: &strings)
                dumps.append(numbers)
                return candidates.map { $0.id }
            }
        }
        let spy = Spy()
        let output = run(seed: 23, weeks: 13, ranker: spy)

        // The truth a cheating ranker would want, straight from ground
        // truth: every session utility and every latent component.
        var forbidden = output.groundTruth.sessions.flatMap { $0.utilities.values }
        for snapshot in output.groundTruth.latentsOverTime {
            for latent in snapshot.latents.values { forbidden += latent }
        }
        XCTAssertFalse(forbidden.isEmpty, "the run must produce truth to protect")
        let sortedForbidden = forbidden.sorted()

        let attendedSessions = output.groundTruth.sessions.filter { !$0.slateIds.isEmpty }
        XCTAssertEqual(spy.dumps.count, attendedSessions.count, "spy saw every ranker call")
        for leaves in spy.dumps {
            XCTAssertFalse(leaves.isEmpty, "the seam carries numeric data to inspect")
            for leaf in leaves {
                let i = ReflectionDump.firstGreaterOrEqual(sortedForbidden, leaf - 1e-9)
                if i < sortedForbidden.count, sortedForbidden[i] < leaf + 1e-9 {
                    XCTFail("ranker-visible leaf \(leaf) matches hidden truth \(sortedForbidden[i])")
                }
            }
        }
    }

    /// The seam's projection carries no recipe internals: candidates built
    /// from fixture recipes reflect no title, no instruction text, and no
    /// ingredient identity — only tags, sizes, and the exposure terms. The
    /// candidate's `id` field is legitimate app metadata (events carry
    /// recipe ids too), but fixture ids are semantic strings that happen to
    /// contain ingredient names, so id-line values are filtered before the
    /// content checks. The real corpus uses opaque numeric ids.
    func testRankerCandidateProjectionExcludesRecipeInternals() {
        let catalog = SimFixtures.catalog()
        let legal = FeasibilityFilter(unionRestrictions: []).legalRecipes(catalog: catalog)
        XCTAssertFalse(legal.isEmpty)
        for recipe in legal {
            let candidate = RankerInput.candidates(
                for: [recipe], availability: [:], exposureCounts: [:])[0]
            var numbers: [Double] = []
            var strings: [String] = []
            ReflectionDump.walk(candidate, path: "", into: &numbers, strings: &strings)
            let dumped = strings.filter { !$0.hasPrefix("id.") }
                .joined(separator: " ").lowercased()
            XCTAssertFalse(
                dumped.contains(recipe.title.lowercased()),
                "candidate leaked the recipe title")
            XCTAssertFalse(
                dumped.contains(recipe.instructions.lowercased()),
                "candidate leaked the instructions (technique source)")
            for use in recipe.requiredIngredients {
                XCTAssertFalse(
                    dumped.contains(use.id.rawValue.lowercased()),
                    "candidate leaked ingredient identity \(use.id.rawValue)")
            }
        }
    }

    /// The funnel is a pure function of observables: for the same feasible
    /// set, availability, exposures, history, and restrictions, ranker
    /// input is identical regardless of which latent produced the run —
    /// the pin for the single-funnel design (its signature has no latent
    /// parameter to leak through).
    func testRankerInputViewIsLatentInvariant() {
        let catalog = SimFixtures.catalog()
        let legal = FeasibilityFilter(unionRestrictions: []).legalRecipes(catalog: catalog)
        let availability = Dictionary(uniqueKeysWithValues: legal.map { ($0.id.rawValue, 1.25) })
        let exposures = Dictionary(uniqueKeysWithValues: legal.map { ($0.id, 2) })
        let candidates = RankerInput.candidates(
            for: legal, availability: availability, exposureCounts: exposures)

        // Two households whose latents differ; the funnel output must not.
        var config = SimFixtures.config(seed: 3, weeks: 1)
        let h1 = HouseholdFactory.generate(config: config, catalog: catalog)
        config.seed = 4
        let h2 = HouseholdFactory.generate(config: config, catalog: catalog)
        XCTAssertNotEqual(h1.eaters[0].latent, h2.eaters[0].latent)

        let view1 = ReflectionDump.of(candidates)
        let view2 = ReflectionDump.of(candidates)
        XCTAssertEqual(view1, view2)
    }

    // MARK: - Blind regime (review objective 2)

    /// The rule-blind regime loads taste ONLY on rule-invisible drivers:
    /// zero on every seam-visible namespace, zero on off-cluster ingredient
    /// identities, nonzero overall, for both household sizes.
    func testBlindRegimeLoadsOnlyRuleInvisibleKeys() {
        let catalog = SimFixtures.catalog()
        let space = FeatureExtractor(catalog: catalog).space
        // Every namespace the ranker projection can influence through tags,
        // sizes, cost, or intercept — all must stay untouched in this regime.
        let visibleNamespaces: Set<String> = [
            "cuisine", "style", "time", "effort", "servings", "cost",
            "complexity", "bias", "nutrition.calorie", "nutrition.protein",
            "nutrition.fiber",
        ]
        let clusterMembers = Set(HouseholdFactory.hiddenAffinityClusters.flatMap { $0 })
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            for size in [1, 2] {
                var config = SimFixtures.config(seed: seed, weeks: 1)
                config.latentRegime = .ruleBlind
                config.householdSize = size
                let household = HouseholdFactory.generate(config: config, catalog: catalog)
                XCTAssertEqual(household.eaters.count, size)
                for eater in household.eaters {
                    var hiddenWeight = 0.0
                    for (index, key) in space.keys.enumerated() {
                        let weight = eater.latent[index]
                        XCTAssertFalse(
                            visibleNamespaces.contains(key.namespace) && weight != 0,
                            "seed \(seed) size \(size): visible key \(key) loaded \(weight)")
                        if key.namespace == "ingredient", weight != 0 {
                            XCTAssertTrue(
                                clusterMembers.contains(key.value),
                                "seed \(seed) size \(size): off-cluster ingredient \(key.value) loaded")
                            hiddenWeight += abs(weight)
                        }
                        if key.namespace == "technique" || key.namespace == "spice" {
                            hiddenWeight += abs(weight)
                        }
                    }
                    XCTAssertGreaterThan(
                        hiddenWeight, 0,
                        "seed \(seed) size \(size): blind regime must load some hidden driver")
                }
            }
        }
    }

    /// The blind regime's point: recipes IDENTICAL on the ranker's visible
    /// projection differ in true utility when the difference is a hidden
    /// driver — hidden-cluster ingredients plus technique from instruction
    /// text. A ranker restricted to the seam sees a tie; a learner that
    /// computes catalog features does not.
    func testBlindRegimeUtilitiesDifferWithIdenticalProjection() throws {
        let ingredients = [
            SimFixtures.ingredient("rice", cal: 130, protein: 2.7, carbs: 28, fat: 0.3, fiber: 0.4),
            SimFixtures.ingredient("onion", cal: 40, protein: 1.1, carbs: 9.3, fat: 0.1, fiber: 1.7),
            SimFixtures.ingredient("carrot", cal: 41, protein: 0.9, carbs: 9.6, fat: 0.2, fiber: 2.8),
            SimFixtures.ingredient("soy_sauce", cal: 53, protein: 8, carbs: 5, fat: 0.1, fiber: 0.8),
            SimFixtures.ingredient("sesame_oil", cal: 884, protein: 0, carbs: 0, fat: 100, fiber: 0),
        ]
        func recipe(_ id: String, required: [(String, Double)], instructions: String) -> CatalogRecipe {
            CatalogRecipe(
                id: RecipeID(id)!, title: id, timeMinutes: 25, servings: 2,
                requiredIngredients: required.map {
                    CatalogRecipe.IngredientUse(id: IngredientID($0.0)!, grams: $0.1)
                },
                optionalIngredients: [], instructions: instructions, tagBitmask: 0)
        }
        // Same tag set (none), time, servings, ingredient count, grams: the
        // seam's projection is identical. The difference is entirely hidden.
        let plain = recipe(
            "r_plain", required: [("rice", 200), ("onion", 50), ("carrot", 50)],
            instructions: "Boil the rice with the onion and carrot.")
        let hidden = recipe(
            "r_hidden", required: [("rice", 200), ("soy_sauce", 50), ("sesame_oil", 50)],
            instructions: "Stir-fry the rice with the soy sauce and sesame oil.")
        let catalog = RecipeCatalog(ingredients: ingredients, recipes: [plain, hidden])

        // A blind-shaped latent: +1 on two hidden-cluster ingredients and
        // one technique key, zero everywhere else.
        let space = FeatureExtractor(catalog: catalog).space
        var latent = [Double](repeating: 0.0, count: space.dimension)
        for key in [
            FeatureKey(namespace: "ingredient", value: "soy_sauce"),
            FeatureKey(namespace: "ingredient", value: "sesame_oil"),
            FeatureKey(namespace: "technique", value: "stirfry"),
        ] {
            let i = try XCTUnwrap(space.index(of: key), "missing hidden key \(key)")
            latent[i] = 1.0
        }
        let household = Household(eaters: [Eater(id: EaterID("e1")!, latent: latent, restrictions: [])])

        // Projection equality, field by field (the id differs by design).
        let candidates = RankerInput.candidates(
            for: [plain, hidden], availability: [:], exposureCounts: [:])
        XCTAssertEqual(candidates.count, 2)
        let a = candidates[0], b = candidates[1]
        XCTAssertEqual(a.tagNames, b.tagNames)
        XCTAssertEqual(a.timeMinutes, b.timeMinutes)
        XCTAssertEqual(a.servings, b.servings)
        XCTAssertEqual(a.requiredIngredientCount, b.requiredIngredientCount)
        XCTAssertEqual(a.optionalIngredientCount, b.optionalIngredientCount)
        XCTAssertEqual(a.availability, b.availability)
        XCTAssertEqual(a.exposureCount, b.exposureCount)

        // ...yet the true utilities differ by exactly the three hidden units.
        let extractor = FeatureExtractor(catalog: catalog)
        let utility: (CatalogRecipe) -> Double = {
            extractor.extract($0, catalog: catalog).dot(latent)
        }
        XCTAssertEqual(utility(hidden) - utility(plain), 3.0, accuracy: 1e-9)
        XCTAssertGreaterThan(utility(hidden), utility(plain))
    }

    /// The regime is active on the app's real corpus too: all four hidden
    /// clusters are present, so blind latents load real drivers there.
    func testBlindRegimeActiveOnRealCorpus() throws {
        guard let path = SimFixtures.repoDataJSONPath() else {
            throw XCTSkip("repo checkout with apps/ios/Resources/data.json not found")
        }
        let json = try String(contentsOfFile: path, encoding: .utf8)
        let catalog = try CatalogLoader.load(dataJSON: json)
        let space = FeatureExtractor(catalog: catalog).space
        var config = SimConfig()
        config.seed = 9
        config.latentRegime = .ruleBlind
        let household = HouseholdFactory.generate(config: config, catalog: catalog)
        let clusterMembers = Set(HouseholdFactory.hiddenAffinityClusters.flatMap { $0 })
        for eater in household.eaters {
            var hiddenWeight = 0.0
            var clusterLoad = 0.0
            for (index, key) in space.keys.enumerated() {
                let weight = eater.latent[index]
                XCTAssertFalse(
                    ["cuisine", "style", "time", "effort"].contains(key.namespace)
                        && weight != 0, "visible key \(key) loaded on the real corpus")
                if key.namespace == "ingredient", weight != 0 {
                    XCTAssertTrue(
                        clusterMembers.contains(key.value),
                        "off-cluster ingredient \(key.value) loaded on the real corpus")
                    clusterLoad += abs(weight)
                }
                if key.namespace == "technique" || key.namespace == "spice" {
                    hiddenWeight += abs(weight)
                }
            }
            hiddenWeight += clusterLoad
            XCTAssertGreaterThan(hiddenWeight, 0, "blind regime inactive on the real corpus")
            XCTAssertGreaterThan(
                clusterLoad, 0, "hidden clusters absent from the real corpus")
        }
    }
}

/// Test-only reflection walk used to prove what the ranker seam carries.
/// Mirrors every value transitively, collecting numeric and string leaves
/// with their paths.
private enum ReflectionDump {
    static func of(_ value: Any) -> String {
        var numbers: [Double] = []
        var strings: [String] = []
        walk(value, path: "", into: &numbers, strings: &strings)
        return strings.joined(separator: "\n")
    }

    static func walk(
        _ value: Any, path: String, into numbers: inout [Double], strings: inout [String]
    ) {
        switch value {
        case let s as String:
            strings.append("\(path)=\(s)")
        case let i as Int:
            numbers.append(Double(i))
        case let i as Int64:
            numbers.append(Double(i))
        case let d as Double:
            numbers.append(d)
        case is Bool:
            break
        default:
            for child in Mirror(reflecting: value).children {
                let label = child.label ?? "[]"
                walk(
                    child.value, path: path.isEmpty ? label : "\(path).\(label)",
                    into: &numbers, strings: &strings)
            }
        }
    }

    /// First index whose value is >= bound (binary search).
    static func firstGreaterOrEqual(_ sorted: [Double], _ bound: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < bound { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
