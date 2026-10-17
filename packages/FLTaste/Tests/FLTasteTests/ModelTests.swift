import XCTest

@testable import FLTaste

/// Behavioral tests for the user model, ranking, explanations and hard
/// filters. Every test drives the public engine API (ingest → rank) and
/// asserts observable outcomes — never posterior internals.
final class ModelTests: XCTestCase {
    // MARK: Fixtures

    /// A small catalog whose recipes share everything except one
    /// distinguishing ingredient, so ranking differences trace to single
    /// features. All recipes: 25 min, 2 servings, no tags.
    private func makeCatalog() -> RecipeCatalog {
        func ingredient(_ id: String, _ name: String) -> CatalogIngredient {
            CatalogIngredient(
                id: IngredientID(id)!, name: name, caloriesPer100g: 100, proteinPer100g: 5,
                carbsPer100g: 10, fatPer100g: 3, fiberPer100g: 2)
        }
        let ingredients = [
            ingredient("rice", "Rice"), ingredient("beans", "Beans"),
            ingredient("peanut_butter", "Peanut butter"), ingredient("shrimp", "Shrimp"),
            ingredient("tofu", "Tofu"),
        ]
        func recipe(_ id: String, _ ingredients: [String]) -> CatalogRecipe {
            CatalogRecipe(
                id: RecipeID(id)!, title: id, timeMinutes: 25, servings: 2,
                requiredIngredients: ingredients.map {
                    CatalogRecipe.IngredientUse(id: IngredientID($0)!, grams: 200)
                },
                optionalIngredients: [], instructions: "1. Cook.", tagBitmask: 0)
        }
        return RecipeCatalog(
            ingredients: ingredients,
            recipes: [
                recipe("r_rice", ["rice"]),
                recipe("r_rice_peanut", ["rice", "peanut_butter"]),
                recipe("r_shrimp", ["shrimp"]),
                recipe("r_tofu", ["tofu"]),
            ],
            allergenGroups: ["peanuts": Set([IngredientID("peanut_butter")!])])
    }

    private func makeEngine(
        _ catalog: RecipeCatalog, config: TasteConfig = .standard
    ) -> TasteEngine {
        TasteEngine(catalog: catalog, config: config)
    }

    private static let anchorDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func instant(_ daysBeforeAnchor: Int64 = 0) -> Instant {
        Instant(Self.anchorDate.addingTimeInterval(-Double(daysBeforeAnchor) * 86_400))
    }

    private func cooked(
        _ id: String, _ recipe: String, at: Instant, rating: Int? = nil,
        wouldMakeAgain: Bool? = nil, shown: Int? = nil, feasible: Int = 6
    ) throws -> TasteEvent {
        var exposure: ExposureContext?
        if let shown {
            exposure = try ExposureContext(feasibleCandidates: feasible, shownCandidates: shown)
        }
        return TasteEvent(
            id: EventID(id)!, at: at, eater: EaterID("sam")!, exposure: exposure,
            kind: .cooked(
                recipe: RecipeID(recipe)!, rating: rating.flatMap(Rating.init),
                wouldMakeAgain: wouldMakeAgain))
    }

    /// Score gap between two candidates in a fixed ranking, explore off.
    private func gap(
        _ engine: TasteEngine, top: String, bottom: String
    ) -> Double {
        var rng = SeededRNG(seed: 7)
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID(top)!, RecipeID(bottom)!],
                context: RankContext(explore: false)), rng: &rng)
        let topRow = ranked.first { $0.recipe.rawValue == top }
        let bottomRow = ranked.first { $0.recipe.rawValue == bottom }
        guard let topRow, let bottomRow else { return -.infinity }
        return topRow.score - bottomRow.score
    }

    // MARK: Learned ranking

    func testPositiveCooksPromoteALovedRecipe() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest(try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: 6))
        var rng = SeededRNG(seed: 7)
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID("r_tofu")!, RecipeID("r_rice")!],
                context: RankContext(explore: false)), rng: &rng)
        XCTAssertEqual(ranked.first?.recipe.rawValue, "r_rice")
    }

    func testNegativeFeedbackDemotesARecipe() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest([
            try cooked("c1", "r_rice", at: instant(), rating: 1, wouldMakeAgain: false, shown: 6),
            TasteEvent(
                id: EventID("l1")!, at: instant(), eater: EaterID("sam")!, exposure: nil,
                kind: .leChefFeedback(
                    recipe: RecipeID("r_rice")!,
                    feedback: LeChefFeedback(type: .tooSpicy, note: nil))),
        ])
        var rng = SeededRNG(seed: 7)
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID("r_tofu")!, RecipeID("r_rice")!],
                context: RankContext(explore: false)), rng: &rng)
        XCTAssertEqual(ranked.first?.recipe.rawValue, "r_tofu")
    }

    func testLowVarietyExposureWeakensEvidence() throws {
        let catalog = makeCatalog()
        func engineWithCook(shown: Int) throws -> TasteEngine {
            var engine = makeEngine(catalog)
            engine.ingest(
                try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: shown))
            return engine
        }
        let fullVariety = gap(try engineWithCook(shown: 6), top: "r_rice", bottom: "r_tofu")
        let forced = gap(try engineWithCook(shown: 1), top: "r_rice", bottom: "r_tofu")
        // The same loved cook, but chosen from a nearly empty shown list is
        // weaker evidence (WEIGHTING-1): still positive, strictly weaker.
        XCTAssertGreaterThan(fullVariety, 0)
        XCTAssertGreaterThan(fullVariety, forced)
        XCTAssertGreaterThan(forced, 0, "the floor keeps confounded evidence positive")
    }

    func testOldEvidenceCountsLessThanFreshEvidence() throws {
        let catalog = makeCatalog()
        func engineWithCook(ageDays: Int64) throws -> TasteEngine {
            var engine = makeEngine(catalog)
            // The old cook ages against the log anchor set by a recent
            // unrelated event; the fresh cook IS the anchor.
            engine.ingest([
                try cooked("c1", "r_rice", at: instant(ageDays), rating: 5, wouldMakeAgain: true, shown: 6),
                TasteEvent(
                    id: EventID("v1")!, at: instant(), eater: EaterID("sam")!, exposure: nil,
                    kind: .viewed(recipe: RecipeID("r_tofu")!)),
            ])
            return engine
        }
        let fresh = gap(try engineWithCook(ageDays: 0), top: "r_rice", bottom: "r_tofu")
        let old = gap(try engineWithCook(ageDays: 400), top: "r_rice", bottom: "r_tofu")
        XCTAssertGreaterThan(fresh, old)
        // At a 120-day cooked half-life, 400 days leaves about a tenth.
        XCTAssertLessThan(old, 0.2 * fresh)
    }

    func testCorrectionsReachTheModel() throws {
        // A corrected cook (rating 2 → 5) must rank identically to a
        // directly-ingested 5-star cook.
        let catalog = makeCatalog()
        var corrected = makeEngine(catalog)
        corrected.ingest([
            try cooked("c1", "r_rice", at: instant(), rating: 2, shown: 6),
            TasteEvent(
                id: EventID("x1")!, at: instant(), eater: nil, exposure: nil,
                kind: .correction(amends: EventID("c1")!, resolution: .setRating(Rating(5)!))),
        ])
        var direct = makeEngine(catalog)
        direct.ingest(try cooked("d1", "r_rice", at: instant(), rating: 5, shown: 6))
        let a = gap(corrected, top: "r_rice", bottom: "r_tofu")
        let b = gap(direct, top: "r_rice", bottom: "r_tofu")
        XCTAssertEqual(a, b, accuracy: 1e-12)
    }

    // MARK: Explicit layers

    func testStatedDislikeChangesRankingImmediatelyAndPredictably() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest(try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: 6))
        let candidates = [RecipeID("r_tofu")!, RecipeID("r_rice")!]
        // Before: the loved rice recipe leads.
        var rng = SeededRNG(seed: 7)
        XCTAssertEqual(
            engine.rank(
                RankInput(candidates: candidates, context: RankContext(explore: false)),
                rng: &rng).first?.recipe.rawValue, "r_rice")
        // Documented direction: one stated dislike ("this is wrong") drops
        // the recipe below the untouched alternative immediately.
        engine.ingest(
            TasteEvent(
                id: EventID("p1")!, at: instant(), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(
                    .setPreference(
                        feature: FeatureKey(namespace: "ingredient", value: "rice"),
                        polarity: .dislike))))
        var rng2 = SeededRNG(seed: 7)
        let after = engine.rank(
            RankInput(candidates: candidates, context: RankContext(explore: false)), rng: &rng2)
        XCTAssertEqual(after.first?.recipe.rawValue, "r_tofu")
        let riceRow = try XCTUnwrap(after.first { $0.recipe.rawValue == "r_rice" })
        XCTAssertTrue(
            riceRow.contributions.contains { $0.feature.key == "ingredient.rice" && $0.contribution < 0 },
            "the ranking change cites the disliked ingredient with a negative contribution")
    }

    func testHouseholdRanksUnionOfHardRestrictions() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest([
            TasteEvent(
                id: EventID("p1")!, at: instant(), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(
                    .setRestriction(Restriction(kind: .allergy, target: "peanut_butter", source: "setup")))),
            TasteEvent(
                id: EventID("p2")!, at: instant(), eater: EaterID("lena")!, exposure: nil,
                kind: .profileEdit(
                    .setRestriction(Restriction(kind: .allergy, target: "shrimp", source: "setup")))),
        ])
        var rng = SeededRNG(seed: 7)
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID("r_rice_peanut")!, RecipeID("r_shrimp")!, RecipeID("r_tofu")!],
                context: RankContext(explore: false)), rng: &rng)
        XCTAssertEqual(
            ranked.map(\.recipe.rawValue), ["r_tofu"],
            "recipes containing either eater's allergen are filtered before the model")
    }

    func testHardFilterSurvivesAdversarialConfigsAndDraws() throws {
        let catalog = makeCatalog()
        var adversarial = TasteConfig.standard
        adversarial.priorWeightVariance = 1_000_000
        adversarial.observationNoiseVariance = 0.000_001
        adversarial.explorationInflation = 1_000
        var engine = makeEngine(catalog, config: adversarial)
        engine.ingest(
            TasteEvent(
                id: EventID("p1")!, at: instant(), eater: nil, exposure: nil,
                kind: .profileEdit(
                    .setRestriction(Restriction(kind: .allergy, target: "peanuts", source: "setup")))))
        for seed: UInt64 in 0..<50 {
            var rng = SeededRNG(seed: seed)
            let ranked = engine.rank(
                RankInput(candidates: [RecipeID("r_rice_peanut")!, RecipeID("r_tofu")!]), rng: &rng)
            XCTAssertFalse(
                ranked.contains { $0.recipe.rawValue == "r_rice_peanut" },
                "seed \(seed) surfaced a peanut recipe")
        }
        // And on the no-eater baseline path, with the target given as a
        // display name instead of an id.
        var fresh = makeEngine(catalog, config: adversarial)
        fresh.ingest(
            TasteEvent(
                id: EventID("p1")!, at: instant(), eater: nil, exposure: nil,
                kind: .profileEdit(
                    .setRestriction(Restriction(kind: .allergy, target: "peanut butter", source: "setup")))))
        var rng = SeededRNG(seed: 3)
        let ranked = fresh.rank(
            RankInput(candidates: [RecipeID("r_rice_peanut")!]), rng: &rng)
        XCTAssertTrue(ranked.isEmpty)
    }

    // MARK: Household and cold start

    func testHouseholdMergeAveragesOpposedStatedTastes() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest([
            TasteEvent(
                id: EventID("p1")!, at: instant(), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(
                    .setPreference(
                        feature: FeatureKey(namespace: "ingredient", value: "shrimp"),
                        polarity: .like))),
            TasteEvent(
                id: EventID("p2")!, at: instant(), eater: EaterID("lena")!, exposure: nil,
                kind: .profileEdit(
                    .setPreference(
                        feature: FeatureKey(namespace: "ingredient", value: "shrimp"),
                        polarity: .dislike))),
        ])
        var rng = SeededRNG(seed: 7)
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID("r_shrimp")!, RecipeID("r_tofu")!],
                context: RankContext(explore: false)), rng: &rng)
        let shrimp = try XCTUnwrap(ranked.first { $0.recipe.rawValue == "r_shrimp" })
        let tofu = try XCTUnwrap(ranked.first { $0.recipe.rawValue == "r_tofu" })
        // The household eats one meal: a recipe one loves and the other
        // hates scores like an untouched recipe.
        XCTAssertEqual(shrimp.score, tofu.score, accuracy: 1e-9)
    }

    func testColdStartOrderMatchesBaselineUntilEvidenceAccumulates() throws {
        let catalog = makeCatalog()
        var learner = makeEngine(catalog)
        learner.ingest(try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: 6))
        let fresh = makeEngine(catalog)
        let input = RankInput(
            candidates: [RecipeID("r_tofu")!, RecipeID("r_rice")!],
            context: RankContext(explore: false))
        var rngA = SeededRNG(seed: 7)
        var rngB = SeededRNG(seed: 7)
        let learned = learner.rank(input, rng: &rngA)
        let baseline = fresh.rank(input, rng: &rngB)
        // One cook is far below coldStartEvidence: ranking still follows the
        // rule-ranker baseline (the tie breaks to the same id order).
        XCTAssertEqual(learned.map(\.recipe.rawValue), baseline.map(\.recipe.rawValue))
        // But the evidence has already begun to move the score.
        XCTAssertGreaterThan(
            gap(learner, top: "r_rice", bottom: "r_tofu"),
            gap(fresh, top: "r_rice", bottom: "r_tofu"))
    }

    // MARK: Explanations

    func testContributionsSumToTheLearnedUtility() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest(try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: 6))
        var rng = SeededRNG(seed: 7)
        // r_shrimp and r_tofu have no cook history, so their expected
        // utility is exactly the learned part the explanation decomposes.
        let ranked = engine.rank(
            RankInput(
                candidates: [RecipeID("r_shrimp")!, RecipeID("r_tofu")!],
                context: RankContext(explore: false)), rng: &rng)
        for row in ranked {
            let sum = row.contributions.reduce(0) { $0 + $1.contribution }
            XCTAssertEqual(sum, row.expectedUtility, accuracy: 1e-9)
            XCTAssertFalse(row.contributions.isEmpty)
        }
        // The loved recipe cites rice, positively.
        var rng2 = SeededRNG(seed: 7)
        let riceRow = try XCTUnwrap(
            engine.rank(
                RankInput(candidates: [RecipeID("r_rice")!], context: RankContext(explore: false)),
                rng: &rng2).first)
        XCTAssertTrue(
            riceRow.contributions.contains { $0.feature.key == "ingredient.rice" && $0.contribution > 0 })
    }

    func testAblatingACitedFeatureMovesTheScore() throws {
        // Two engines differing only in the sign of the evidence about rice:
        // the cited rice contribution must move, and carry the recipe with it.
        let catalog = makeCatalog()
        var loved = makeEngine(catalog)
        loved.ingest(try cooked("c1", "r_rice", at: instant(), rating: 5, wouldMakeAgain: true, shown: 6))
        var avoided = makeEngine(catalog)
        avoided.ingest(try cooked("c1", "r_rice", at: instant(), rating: 1, wouldMakeAgain: false, shown: 6))
        let input = RankInput(candidates: [RecipeID("r_rice")!], context: RankContext(explore: false))
        var rngA = SeededRNG(seed: 7)
        var rngB = SeededRNG(seed: 7)
        let lovedRow = try XCTUnwrap(loved.rank(input, rng: &rngA).first)
        let avoidedRow = try XCTUnwrap(avoided.rank(input, rng: &rngB).first)
        let lovedContribution = try XCTUnwrap(
            lovedRow.contributions.first { $0.feature.key == "ingredient.rice" }).contribution
        let avoidedContribution = try XCTUnwrap(
            avoidedRow.contributions.first { $0.feature.key == "ingredient.rice" }).contribution
        XCTAssertGreaterThan(lovedContribution, avoidedContribution)
        XCTAssertLessThan(avoidedContribution, 0, "negative evidence pulls the cited weight below zero")
        XCTAssertGreaterThan(lovedRow.expectedUtility, avoidedRow.expectedUtility)
    }

    // MARK: Determinism

    func testRankingIsDeterministicForASeed() throws {
        let catalog = makeCatalog()
        var engine = makeEngine(catalog)
        engine.ingest([
            try cooked("c1", "r_rice", at: instant(), rating: 4, shown: 6),
            try cooked("c2", "r_tofu", at: instant(), rating: 3, shown: 6),
        ])
        let input = RankInput(
            candidates: [RecipeID("r_rice")!, RecipeID("r_tofu")!, RecipeID("r_shrimp")!])
        var rngA = SeededRNG(seed: 42)
        var rngB = SeededRNG(seed: 42)
        XCTAssertEqual(engine.rank(input, rng: &rngA), engine.rank(input, rng: &rngB))
    }
}
