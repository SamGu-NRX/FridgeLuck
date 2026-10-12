import FLTaste
@testable import FLTasteSim
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
            XCTAssertEqual(
                result.independentRestrictionViolations, 0,
                "\(result.arm): zero independent (fail-closed) slate violations")
            XCTAssertEqual(result.coverageFailures, 0, "\(result.arm): every ranked week has ground truth")
            XCTAssertGreaterThan(result.rankedSessions, 0, "\(result.arm): ranked something")
            let ndcg = try XCTUnwrap(result.meanNDCG, "\(result.arm): NDCG measurable")
            XCTAssertTrue(ndcg.isFinite && ndcg >= 0 && ndcg <= 1, "\(result.arm): NDCG in [0, 1]")
            // Recovery observations are one per started shift: every value
            // is a positive cook count inside the horizon.
            XCTAssertTrue(
                result.recoveryObservations.allSatisfy { $0 >= 1 && $0 <= 100 }
                    && result.recoveryCensored >= 0,
                "\(result.arm): recovery observations sane")
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
        let random = RandomArm()

        // One household, run through the public simulator with a test-local
        // capture. The oracle is POST-HOC: the post-seam ranker input is a
        // proven-latent-free projection, so the "oracle" is the ground
        // truth's own per-session trueRanking, scored through the same
        // scoreHousehold every arm goes through. Same assurance as the old
        // seam-level oracle arm, without touching the sealed seam.
        final class CaptureBox: @unchecked Sendable {
            var log: [(week: Int, ordered: [RecipeID])] = []
        }
        struct CaptureRanker: Ranker {
            let inner: RandomRanker
            let box: CaptureBox
            var id: String { inner.id }
            func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
                let ordered = inner.rank(candidates, context: context)
                box.log.append((context.week, ordered))
                return ordered
            }
        }

        let seed: UInt64 = 101
        let (config, _) = Regimes.config(seed: seed, householdIndex: 0, weeks: 5)
        let armSeed = SeedDeriver.child(seed, "arm-random", 0)
        let box = CaptureBox()
        let ranker = CaptureRanker(
            inner: RandomRanker(seed: SeedDeriver.child(armSeed, "random-rank", Int(config.seed % 1_000_003))),
            box: box)
        let run = HouseholdSimulator(config: config, catalog: catalog, ranker: ranker).run()
        XCTAssertFalse(box.log.isEmpty, "the household ranked at least one session")

        let randomMetrics = scoreHousehold(
            groundTruth: run.groundTruth, catalog: catalog, rankLog: box.log)
        let oracleMetrics = scoreHousehold(
            groundTruth: run.groundTruth, catalog: catalog,
            rankLog: oracleRankLog(groundTruth: run.groundTruth))
        let randomNDCG = try XCTUnwrap(randomMetrics.meanNDCG)
        let oracleNDCG = try XCTUnwrap(oracleMetrics.meanNDCG)
        XCTAssertGreaterThan(oracleNDCG, 0.9, "the true ranking scores near the ceiling")
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
                    restrictionViolations: 0, independentRestrictionViolations: 0,
                    coverageFailures: 0, medianRecoveryCooks: 3,
                    recoveryDistribution: [:], recoveryObservations: [3], recoveryCensored: 0,
                    meanKendallTau: nil,
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

    // MARK: Hash-bound resume

    func testSHA256KnownVectors() {
        XCTAssertEqual(
            SHA256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            SHA256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testCanonicalConfigOrderIndependent() {
        let a = canonicalConfigString(
            householdsPerSeed: 5, weeks: 12, bootstrapResamples: 1_000,
            seeds: [3, 1, 2], armIDs: ["engine", "random"])
        let b = canonicalConfigString(
            householdsPerSeed: 5, weeks: 12, bootstrapResamples: 1_000,
            seeds: [1, 2, 3], armIDs: ["random", "engine"])
        XCTAssertEqual(a, b, "set-equal configs hash equal")
        XCTAssertNotEqual(
            a,
            canonicalConfigString(
                householdsPerSeed: 6, weeks: 12, bootstrapResamples: 1_000,
                seeds: [1, 2, 3], armIDs: ["engine", "random"]),
            "a household change changes the config hash")
    }

    func testCheckpointFingerprintRejection() {
        let current = ResumeFingerprint(
            configHash: "c", corpusHash: "d", codeHash: "e", metricsVersion: "2")
        XCTAssertTrue(checkpointAcceptable(saved: current, current: current))
        XCTAssertFalse(
            checkpointAcceptable(saved: nil, current: current),
            "unfingerprinted (schema-old) checkpoints are stale")
        XCTAssertFalse(
            checkpointAcceptable(
                saved: ResumeFingerprint(
                    configHash: "OTHER", corpusHash: "d", codeHash: "e", metricsVersion: "2"),
                current: current),
            "a config change rejects resume")
        XCTAssertFalse(
            checkpointAcceptable(
                saved: ResumeFingerprint(
                    configHash: "c", corpusHash: "OTHER", codeHash: "e", metricsVersion: "2"),
                current: current),
            "a corpus change rejects resume")
        XCTAssertFalse(
            checkpointAcceptable(
                saved: ResumeFingerprint(
                    configHash: "c", corpusHash: "d", codeHash: "e", metricsVersion: "1"),
                current: current),
            "a metrics-version bump rejects resume")
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

        // Independent fail-closed violations gate the activation too (three
        // seeds so the paired lift exists and only the zero-field flips it).
        var unsafe: [ArmSeedResult] = []
        for i in 0..<3 {
            func makeOne(_ arm: String, _ family: String, _ seed: UInt64, _ ndcg: Double) -> ArmSeedResult {
                ArmSeedResult(
                    arm: arm, family: family, seed: seed, households: 2, sessions: 10,
                    rankedSessions: 10, cookedSessions: 8, meanNDCG: ndcg, bestInSlateRate: nil,
                    meanChoiceRank: nil, meanRegret: 0.1, meanExposureRegret: nil,
                    restrictionViolations: 0, independentRestrictionViolations: arm == "engine" ? 1 : 0,
                    coverageFailures: 0, medianRecoveryCooks: 3,
                    recoveryDistribution: [:], recoveryObservations: [3], recoveryCensored: 0,
                    meanKendallTau: nil, repeatRate: nil, meanFairnessGap: nil, perRegime: [:])
            }
            unsafe.append(makeOne("engine", "family-2", UInt64(300 + i), 0.60))
            unsafe.append(makeOne("rule-port", "baseline", UInt64(300 + i), 0.50))
            unsafe.append(makeOne("profile-only", "baseline", UInt64(300 + i), 0.48))
        }
        let unsafeVerdict = gateVerdict(
            results: unsafe, engineArm: "engine", ruleArm: "rule-port",
            profileArm: "profile-only", resamples: 200)
        XCTAssertEqual(
            try XCTUnwrap(unsafeVerdict).activationGateMet, false,
            "one unsafe slate suggestion fails the gate")
    }

    // MARK: Review-rework integrity fixes

    func testNDCGIdealUsesFullFeasibleUniverse() {
        let utilities = ["a": 1.0, "b": 0.5, "c": 0.1]
        // An arm that drops the best feasible recipe must NOT score 1.0.
        let dropping = ndcg10(ordered: ["b", "c"], feasible: ["a", "b", "c"], utilities: utilities)
        let complete = ndcg10(ordered: ["a", "b", "c"], feasible: ["a", "b", "c"], utilities: utilities)
        XCTAssertEqual(complete, 1.0, accuracy: 1e-12)
        XCTAssertLessThan(dropping, 1.0, "omitting the best feasible recipe costs NDCG")
    }

    func testPooledMedianRecoveryCensoredConventions() {
        // Plain odd/even medians over observations.
        XCTAssertEqual(pooledMedianRecovery(observations: [3, 2, 9], censored: 0), 3.0)
        XCTAssertEqual(pooledMedianRecovery(observations: [3, 2], censored: 0), 2.5)
        // Censored shifts sort last; a median landing on them is nil (fail).
        XCTAssertEqual(pooledMedianRecovery(observations: [2, 4], censored: 1), 4.0)
        XCTAssertNil(pooledMedianRecovery(observations: [2], censored: 1), "median falls on a censored shift")
        XCTAssertNil(pooledMedianRecovery(observations: [], censored: 2), "all censored")
        XCTAssertNil(pooledMedianRecovery(observations: [], censored: 0), "no shifts ever started")
    }

    func testRestrictionExpectationsFailClosedAndCompound() throws {
        let catalog = try loadCatalog()

        // Allergy whose target resolves only through the head-token net:
        // any recipe using a peanut-headed compound (e.g. peanut_butter)
        // is unsafe under a "peanuts" allergy even if the exact-id
        // expansion misses it.
        let peanutRecipe = try XCTUnwrap(
            catalog.recipes.values.first { recipe in
                (recipe.requiredIngredients + recipe.optionalIngredients)
                    .contains { $0.id.rawValue.lowercased().contains("peanut") }
            },
            "corpus has a peanut-using recipe for the compound test")
        let peanutAllergy = RestrictionExpectations(
            rules: [RestrictionExpectations.Rule(startWeek: 0, kind: .allergy, target: "peanuts")],
            catalog: catalog)
        XCTAssertGreaterThan(
            peanutAllergy.violations(week: 1, slate: [peanutRecipe.id], neverSuggest: []), 0,
            "an allergen-headed compound is flagged, not just the exact id")

        // Unresolvable restriction target: fail closed — every slate entry
        // is unverifiable and counts.
        let unknown = RestrictionExpectations(
            rules: [RestrictionExpectations.Rule(startWeek: 0, kind: .allergy, target: "dragonfruit_extract")],
            catalog: catalog)
        XCTAssertEqual(
            unknown.violations(week: 1, slate: [peanutRecipe.id], neverSuggest: []), 1,
            "an unknown allergy target makes every suggestion unverifiable")

        // Diet re-verified from the recipe's own tag bitmask.
        let untagged = try XCTUnwrap(
            catalog.recipes.values.first { !$0.hasTag(.vegetarian) },
            "corpus has a non-vegetarian recipe")
        let tagged = try XCTUnwrap(
            catalog.recipes.values.first { $0.hasTag(.vegetarian) },
            "corpus has a vegetarian recipe")
        let vegetarian = RestrictionExpectations(
            rules: [RestrictionExpectations.Rule(startWeek: 0, kind: .diet, target: "vegetarian")],
            catalog: catalog)
        XCTAssertGreaterThan(
            vegetarian.violations(week: 0, slate: [untagged.id], neverSuggest: []), 0)
        XCTAssertEqual(
            vegetarian.violations(week: 0, slate: [tagged.id], neverSuggest: []), 0)

        // A diet shift binds only from its week on.
        XCTAssertEqual(
            vegetarian.violations(week: -1, slate: [untagged.id], neverSuggest: []), 0,
            "before the shift week the diet is not yet binding")

        // Never-suggest is an exact-id preference edit: use an actual
        // ingredient of the picked recipe as the never-suggest target.
        let anyRecipe = try XCTUnwrap(catalog.recipes.values.first, "corpus has recipes")
        let targetUse = try XCTUnwrap(
            (anyRecipe.requiredIngredients + anyRecipe.optionalIngredients).first,
            "the recipe uses at least one ingredient")
        let blockedID = try XCTUnwrap(IngredientID(targetUse.id.rawValue), "the id parses")
        let noRules = RestrictionExpectations(rules: [], catalog: catalog)
        XCTAssertEqual(noRules.violations(week: 1, slate: [anyRecipe.id], neverSuggest: []), 0)
        XCTAssertGreaterThan(
            noRules.violations(week: 1, slate: [anyRecipe.id], neverSuggest: [blockedID]),
            0, "a never-suggested ingredient in the slate is flagged")
    }

    /// Regression for the never-suggest enforcement clock (metrics v4): a
    /// mute becomes countable at the simulator's enforcement granularity —
    /// the next WEEK boundary, not the next session. Sim snapshots
    /// never-suggest into its week-start FeasibilityFilter, so a mid-week
    /// mute cannot reach the ranker-visible candidate set until the next
    /// week regardless of arm behavior (RankInput carries no mute surface);
    /// counting same-week later sessions measures Sim's filter lag, not the
    /// arm. From the boundary on, Sim's own filter excludes the ingredient,
    /// so any hit is a real enforcement failure.
    func testNeverSuggestAppliesAtSimEnforcementGranularity() throws {
        let catalog = try loadCatalog()

        let anyRecipe = try XCTUnwrap(catalog.recipes.values.first, "corpus has recipes")
        let targetUse = try XCTUnwrap(
            (anyRecipe.requiredIngredients + anyRecipe.optionalIngredients).first,
            "the recipe uses at least one ingredient")
        let mutedID = try XCTUnwrap(IngredientID(targetUse.id.rawValue), "the id parses")

        func session(cookIndex: Int, week: Int, mutes: String?) -> GroundTruth.Session {
            GroundTruth.Session(
                week: week, atMillis: Int64(week) * 604_800_000, cookIndex: cookIndex,
                actorId: "eater-0",
                feasibleIds: [anyRecipe.id.rawValue], slateIds: [anyRecipe.id.rawValue],
                choiceId: anyRecipe.id.rawValue, outcome: .cooked,
                trueRanking: [anyRecipe.id.rawValue],
                utilities: [anyRecipe.id.rawValue: 1.0],
                choiceProbabilities: [anyRecipe.id.rawValue: 1.0],
                availability: [anyRecipe.id.rawValue: 1.0], rating: nil, skip: nil,
                substitution: nil, neverSuggestIngredient: mutes)
        }

        // Session 0 (week 0) emits a mute for an ingredient its own slate
        // uses; session 1 (still week 0) shows it too — Sim's candidate
        // filter cannot have excluded it yet; session 2 (week 1) shows it
        // after the boundary. Only session 2 counts.
        let groundTruth = GroundTruth(
            rankerId: "test", seed: 0, weeks: 2, latentRegime: .standard,
            householdInitial: Household(eaters: []), raterBias: [:], shifts: [],
            latentsOverTime: [],
            sessions: [session(cookIndex: 0, week: 0, mutes: mutedID.rawValue),
                       session(cookIndex: 1, week: 0, mutes: nil),
                       session(cookIndex: 2, week: 1, mutes: nil)],
            ratingNoiseDraws: [], missedCooks: 0, eventCount: 0)

        let metrics = scoreHousehold(
            groundTruth: groundTruth, catalog: catalog,
            rankLog: [(week: 0, ordered: [anyRecipe.id]), (week: 0, ordered: [anyRecipe.id]),
                      (week: 1, ordered: [anyRecipe.id])])
        XCTAssertEqual(
            metrics.independentRestrictionViolations, 1,
            "the emitting and same-week slates are not flagged; the post-boundary slate is")
    }
}
