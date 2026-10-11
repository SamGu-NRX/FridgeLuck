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

    /// Every cooked session emits exactly one cooked event; skipped sessions
    /// emit a typed skip and never a cooked event; the pick equals the
    /// recorded choice.
    func testCookAndSkipEventMirroring() throws {
        let output = run(weeks: 10)
        var cookedKinds = 0
        var skipKinds = 0
        for event in output.events {
            if case .cooked = event.kind { cookedKinds += 1 }
            if case .skipped = event.kind { skipKinds += 1 }
        }
        let cookedSessions = output.groundTruth.sessions.filter { $0.outcome == .cooked }
        let skippedSessions = output.groundTruth.sessions.filter { $0.outcome == .skippedSession }
        XCTAssertEqual(cookedKinds, cookedSessions.count)
        XCTAssertEqual(skipKinds, skippedSessions.count)
        for session in skippedSessions {
            XCTAssertNil(session.choiceId, "a skipped session cooks nothing")
            XCTAssertNotNil(session.skip)
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
    /// popularity order actually descending.
    func testReferenceRankersHonorContract() throws {
        let catalog = SimFixtures.catalog()
        let extractor = FeatureExtractor(catalog: catalog)
        let config = SimFixtures.config(seed: 7, weeks: 1)
        let household = HouseholdFactory.generate(config: config, catalog: catalog)
        let filter = FeasibilityFilter(unionRestrictions: household.restrictionUnion)
        let candidates = filter.legalRecipes(catalog: catalog).map { recipe in
            Candidate(
                recipe: recipe,
                householdUtility: extractor.extract(recipe, catalog: catalog)
                    .dot(household.eaters[0].latent),
                availability: 1, exposureCount: 0)
        }
        XCTAssertGreaterThanOrEqual(candidates.count, 8)
        let context = RankingContext(week: 0, slateSize: 6, sessionIndex: 0)

        let random = RandomRanker(seed: 1234)
        let first = random.rank(candidates, context: context)
        let second = random.rank(candidates, context: context)
        XCTAssertEqual(first, second, "same seed + context replays exactly")
        XCTAssertEqual(Set(first), Set(candidates.map { $0.recipe.id }), "a permutation")
        XCTAssertEqual(first.count, candidates.count)

        let popularity = PopularityProxyRanker()
        let order = popularity.rank(candidates, context: context)
        XCTAssertEqual(Set(order), Set(candidates.map { $0.recipe.id }))
        for (a, b) in zip(order, order.dropFirst()) {
            let scoreA = PopularityProxyRanker.popularityScore(catalog.recipes[a]!)
            let scoreB = PopularityProxyRanker.popularityScore(catalog.recipes[b]!)
            XCTAssertTrue(
                scoreA > scoreB || (scoreA == scoreB && a.rawValue < b.rawValue),
                "popularity order descending, ties by id")
        }
    }

    /// A ranker that returns unknown ids is filtered defensively; the
    /// household still sees a slate drawn from the feasible set.
    func testUnknownRankerOutputIsFilteredDefensively() {
        struct Broken: Ranker {
            let id = "broken"
            func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
                [RecipeID("r_ghost")!, RecipeID("r_ghost")!]
                    + candidates.map { $0.recipe.id }
            }
        }
        let output = run(weeks: 4, ranker: Broken())
        for session in output.groundTruth.sessions where !session.slateIds.isEmpty {
            XCTAssertTrue(Set(session.slateIds).isSubset(of: Set(session.feasibleIds)))
            XCTAssertLessThanOrEqual(session.slateIds.count, 6)
        }
    }
}
