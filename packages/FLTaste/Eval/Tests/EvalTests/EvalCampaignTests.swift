import FLTaste
import FLTasteSim
import XCTest

@testable import FLTasteEvalCore

/// End-to-end and unit checks for the suite-B campaign package. The
/// campaign-scale tests run a micro grid (few households, short horizon)
/// chosen to finish in seconds on the 2-core Linux sandbox while still
/// exercising every arm, the staged replay, and the fail-close contract.
final class EvalCampaignTests: XCTestCase {
    /// Loads the real bundled corpus (166 recipes) for campaign tests.
    func loadCatalog() throws -> RecipeCatalog {
        // #filePath → file dir → Tests → Eval → FLTaste → packages → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dataPath = repoRoot.appendingPathComponent("apps/ios/Resources/data.json")
        let dataJSON = try String(contentsOf: dataPath, encoding: .utf8)
        return try CatalogLoader.load(dataJSON: dataJSON)
    }

    /// The 12 registered arms, one shared catalog.
    func loadArms(catalog: RecipeCatalog) -> [any ArmFactory] {
        ArmRegistry.all(catalog: catalog)
    }

    // MARK: Micro campaign

    func runMicroCampaign(
        catalog: RecipeCatalog, arms: [any ArmFactory], households: Int = 2, weeks: Int = 5,
        seed: UInt64 = 101
    ) throws -> [ArmSeedResult] {
        var results: [ArmSeedResult] = []
        for (armIndex, arm) in arms.enumerated() {
            let armSeed = SeedDeriver.child(seed, "arm-\(arm.id)", armIndex)
            var accumulator = ArmSeedAccumulator()
            for index in 0..<households {
                let (config, regime) = Regimes.config(seed: seed, householdIndex: index, weeks: weeks)
                let (metrics, resolvedRegime) = Campaign.runHousehold(
                    arm: arm, config: config, regime: regime, catalog: catalog,
                    householdSeed: config.seed, armSeed: armSeed)
                XCTAssertEqual(resolvedRegime, regime, "regime roundtrip is stable")
                accumulator.add(metrics, regime: regime)
            }
            results.append(
                summarize(arm: arm.id, family: arm.family, seed: seed, households: households, accumulator: accumulator))
        }
        return results
    }

    func testMicroCampaignAllArmsEndToEnd() throws {
        let catalog = try loadCatalog()
        let arms = loadArms(catalog: catalog)
        XCTAssertEqual(arms.count, 12, "the preregistered 12 arms are registered")
        let results = try runMicroCampaign(catalog: catalog, arms: arms)

        // Fail-close contract: every arm present, no violations, no
        // coverage failures, nonempty finite metrics.
        for result in results {
            XCTAssertEqual(result.restrictionViolations, 0, "\(result.arm): zero hard-restriction violations")
            XCTAssertEqual(result.coverageFailures, 0, "\(result.arm): every ranked week has ground truth")
            XCTAssertGreaterThan(result.rankedSessions, 0, "\(result.arm): ranked something")
            let ndcg = try XCTUnwrap(result.meanNDCG, "\(result.arm): NDCG measurable")
            XCTAssertTrue(ndcg.isFinite && ndcg >= 0 && ndcg <= 1, "\(result.arm): NDCG in [0, 1]")
        }
    }

    func testDeterminismByteIdentical() throws {
        let catalog = try loadCatalog()
        let arms = loadArms(catalog: catalog)
        let arm = try XCTUnwrap(arms.first { $0.id == "trust-vector" }, "stateful arm present")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var encodedRuns: [Data] = []
        for _ in 0..<2 {
            let results = try runMicroCampaign(catalog: catalog, arms: [arm], weeks: 4)
            XCTAssertEqual(results.count, 1)
            encodedRuns.append(try encoder.encode(results[0]))
        }
        XCTAssertEqual(encodedRuns[0], encodedRuns[1], "same seed + config => byte-identical result")
    }

    func testOracleBeatsRandom() throws {
        let catalog = try loadCatalog()
        let oracle = OracleArm()
        let random = RandomArm()
        let results = try runMicroCampaign(catalog: catalog, arms: [oracle, random])
        let oracleNDCG = try XCTUnwrap(results.first { $0.arm == "oracle" }?.meanNDCG)
        let randomNDCG = try XCTUnwrap(results.first { $0.arm == "random" }?.meanNDCG)
        XCTAssertGreaterThan(oracleNDCG, 0.9, "oracle ranks the true best at the top")
        XCTAssertGreaterThan(oracleNDCG, randomNDCG, "a correct ranking beats noise")
    }

    // MARK: Rule-ranker port fixtures

    func testRulePortHealthRatingBands() {
        func rating(calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double)
            -> Int
        {
            RuleRankerPort.healthRating(
                macros: RuleRankerPort.Macros(
                    calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber))
        }
        // Actual formula: meal target 2000/3 kcal (ratio 0.7-1.1 → +30),
        // balance max(5, 40*(1-avgDiff*3)) against split 0.25/0.45/0.30,
        // +10 fiber at >=5g, rating ceil(points/20) clamped to 1...5.
        //
        // Balanced macros (125p/225c/150f → split 0.18/0.33/0.49) score
        // ~24.7 balance points.
        let balanced = (125.0, 225.0, 150.0)
        // Ratio ≈ 1.0 (+30) + balance 24.7 + fiber 10 = 64.7 -> 4.
        XCTAssertEqual(rating(calories: 667, protein: balanced.0, carbs: balanced.1, fat: balanced.2, fiber: 6), 4)
        // Same plate at ratio 3.0 (+5): 5 + 24.7 + 10 = 39.7 -> 2.
        XCTAssertEqual(rating(calories: 2000, protein: balanced.0, carbs: balanced.1, fat: balanced.2, fiber: 6), 2)
        // Fiber 4g drops the +10: 30 + 24.7 = 54.7 -> 3.
        XCTAssertEqual(rating(calories: 667, protein: balanced.0, carbs: balanced.1, fat: balanced.2, fiber: 4), 3)
        // Extreme imbalance (300p/20c/10f) floors the balance points at 5:
        // 30 + 5 + 10 = 45 -> 3 (below the balanced plate's 4).
        XCTAssertEqual(rating(calories: 667, protein: 300, carbs: 20, fat: 10, fiber: 6), 3)
    }

    func testRulePortScoresRealCorpus() throws {
        let catalog = try loadCatalog()
        let sortedIDs = catalog.recipes.keys.sorted { $0.rawValue < $1.rawValue }
        let recipeID = try XCTUnwrap(sortedIDs.first, "corpus has recipes")
        let recipe = try XCTUnwrap(catalog.recipes[recipeID])
        let score = RuleRankerPort.rankingScore(recipe: recipe, catalog: catalog)
        XCTAssertTrue(score.isFinite && score > 0, "rule scores are finite and positive")
    }

    // MARK: Statistics

    func testBootstrapDegenerateInterval() {
        let interval = bootstrap(values: [0.5, 0.5, 0.5, 0.5], resamples: 400, seed: 7)
        XCTAssertEqual(interval.low, 0.5, accuracy: 1e-9)
        XCTAssertEqual(interval.high, 0.5, accuracy: 1e-9)
        XCTAssertEqual(interval.mean, 0.5, accuracy: 1e-9)
    }

    func testPairedLiftDetectsStrictImprovement() {
        let engine = (0..<8).map { 0.60 + 0.01 * Double($0 % 2) }
        let baseline = (0..<8).map { 0.50 + 0.01 * Double($0 % 2) }
        let lift = pairedLift(
            engineSeedNDCG: engine, baselineSeedNDCG: baseline, baselineArm: "rule-port",
            resamples: 2_000)
        XCTAssertGreaterThan(lift.ciLow, 0.0, "a consistent +20% lift has an interval above zero")
        XCTAssertGreaterThan(lift.ciLow, 0.10, "the gate needs the low end above +10% relative")
        XCTAssertTrue(lift.gateLowMet)
    }

    func testGateVerdictSyntheticMetAndUnmet() {
        func makeResults(engine: [Double], rule: [Double], profile: [Double]) -> [ArmSeedResult] {
            func makeOne(_ arm: String, _ family: String, _ seed: UInt64, _ ndcg: Double)
                -> ArmSeedResult
            {
                ArmSeedResult(
                    arm: arm, family: family, seed: seed, households: 2, sessions: 10,
                    rankedSessions: 10, cookedSessions: 8, meanNDCG: ndcg, bestInSlateRate: nil,
                    meanChoiceRank: nil, meanRegret: 0.1, meanExposureRegret: nil,
                    restrictionViolations: 0, coverageFailures: 0, medianRecoveryCooks: 3,
                    recoveryDistribution: [:], recoveryCensored: 0, meanKendallTau: nil,
                    repeatRate: nil, meanFairnessGap: nil, perRegime: [:])
            }
            var results: [ArmSeedResult] = []
            for i in 0..<3 {
                results.append(makeOne("engine", "family-2", UInt64(200 + i), engine[i]))
                results.append(makeOne("rule-port", "baseline", UInt64(200 + i), rule[i]))
                results.append(makeOne("profile-only", "baseline", UInt64(200 + i), profile[i]))
            }
            return results
        }

        let met = gateVerdict(
            results: makeResults(
                engine: [0.60, 0.61, 0.60], rule: [0.50, 0.50, 0.51], profile: [0.48, 0.49, 0.48]),
            engineArm: "engine", ruleArm: "rule-port", profileArm: "profile-only", resamples: 2_000)
        let metVerdict = try? XCTUnwrap(met)
        XCTAssertEqual(metVerdict?.activationGateMet, true, "clear +20% lift meets the gate")

        let unmet = gateVerdict(
            results: makeResults(
                engine: [0.40, 0.41, 0.40], rule: [0.50, 0.50, 0.51], profile: [0.48, 0.49, 0.48]),
            engineArm: "engine", ruleArm: "rule-port", profileArm: "profile-only", resamples: 2_000)
        XCTAssertEqual(try XCTUnwrap(unmet).activationGateMet, false, "a losing engine fails the gate")
    }

    // MARK: Fail-close contract (planted failure)

    func testPlantedFailureIsRejected() throws {
        let catalog = try loadCatalog()
        let arms = loadArms(catalog: catalog)
        let roster = arms.map {
            ArmRosterEntry(
                id: $0.id, family: $0.family, rationale: $0.rationale, stateless: $0.isStateless)
        }

        // A clean micro run passes the contract.
        let clean = try runMicroCampaign(catalog: catalog, arms: arms, households: 1, weeks: 3)
        XCTAssertTrue(
            SuiteContract.validate(results: clean, roster: roster).isEmpty,
            "a clean run publishes")

        // Plant failures: a restriction violation, a non-finite metric,
        // and one arm's results dropped entirely. All must be flagged.
        var planted = clean
        planted[0].restrictionViolations = 3
        planted[0].meanNDCG = .nan
        let droppedArm = planted[1].arm
        planted = planted.filter { $0.arm != droppedArm }
        let problems = SuiteContract.validate(results: planted, roster: roster)
        XCTAssertTrue(
            problems.contains { $0.contains("restriction violations") },
            "planted violations are flagged")
        XCTAssertTrue(
            problems.contains { $0.contains("NDCG") },
            "planted non-finite metrics are flagged")
        XCTAssertTrue(
            problems.contains { $0.contains("missing arm results") },
            "a missing arm fails close")
        XCTAssertEqual(planted[0].restrictionViolations, 3, "the plant stays planted (no normalization)")
    }
}
