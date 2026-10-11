import XCTest

@testable import FLTaste

/// Profile-sentence behavior: real counts and recency in the text, the
/// sentence policy (thresholds, expiry), and edits that change rankings
/// immediately and predictably. All sentences are read off `engine.profile()`.
final class ProfileTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func instant(_ daysAfterBase: Int64) -> Instant {
        Instant(Self.base.addingTimeInterval(Double(daysAfterBase) * 86_400))
    }

    /// Five cilantro recipes, five shrimp recipes, one peanut recipe — one
    /// ingredient per recipe, all 25 minutes, so counts are unambiguous.
    private func makeEngine() -> TasteEngine {
        func ingredient(_ id: String) -> CatalogIngredient {
            CatalogIngredient(
                id: IngredientID(id)!, name: id, caloriesPer100g: 100, proteinPer100g: 5,
                carbsPer100g: 10, fatPer100g: 3, fiberPer100g: 2)
        }
        let ingredients = ["cilantro", "shrimp", "peanut_butter", "rice"].map(ingredient)
        func recipe(_ id: String, _ name: String) -> CatalogRecipe {
            CatalogRecipe(
                id: RecipeID(id)!, title: name, timeMinutes: 25, servings: 2,
                requiredIngredients: [CatalogRecipe.IngredientUse(id: IngredientID(name)!, grams: 100)],
                optionalIngredients: [], instructions: "1. Cook.", tagBitmask: 0)
        }
        let recipes = (1...5).map { recipe("r_c\($0)", "cilantro") }
            + (1...5).map { recipe("r_s\($0)", "shrimp") }
            + [recipe("r_peanut", "peanut_butter")]
        return TasteEngine(
            catalog: RecipeCatalog(
                ingredients: ingredients, recipes: recipes, allergenGroups: [:]))
    }

    private func cook(_ id: String, _ recipe: String, at: Instant, rating: Int?) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: EaterID("sam")!, exposure: nil,
            kind: .cooked(recipe: RecipeID(recipe)!, rating: rating.flatMap(Rating.init), wouldMakeAgain: nil))
    }

    private func removed(_ id: String, _ recipe: String, _ ingredient: String, at: Instant) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: EaterID("sam")!, exposure: nil,
            kind: .substituted(recipe: RecipeID(recipe)!, from: IngredientID(ingredient)!, to: nil, mode: nil))
    }

    private func sentence(_ profile: TasteProfile, _ id: String) -> ProfileSentence? {
        profile.sentences.first { $0.id == id }
    }

    // MARK: Learned sentences

    func testAvoidSentenceCitesActualRemovalCounts() {
        var engine = makeEngine()
        for i in 1...5 {
            engine.ingest([
                cook("k\(i)", "r_c\(i)", at: instant(1), rating: 3),
            ])
        }
        for i in 1...4 {
            engine.ingest([removed("x\(i)", "r_c\(i)", "cilantro", at: instant(2))])
        }
        let s = sentence(engine.profile(), "learned.avoid.ingredient.cilantro")
        XCTAssertNotNil(s, "4 removals of 5 cooked appearances must render")
        XCTAssertEqual(s?.evidence.numerator, 4)
        XCTAssertEqual(s?.evidence.denominator, 5)
        XCTAssertTrue(s?.text.contains("removed it 4 of the 5 times") ?? false, s?.text ?? "")
        XCTAssertTrue(s?.text.contains("most recently today") ?? false, s?.text ?? "")
        // The offered correction is the strong one: pin the opposite.
        XCTAssertEqual(
            s?.edits.thisIsWrong,
            .setPreference(feature: FeatureKey(namespace: "ingredient", value: "cilantro"), polarity: .like))
    }

    func testLeanSentenceCitesActualPositiveCooks() {
        var engine = makeEngine()
        for (i, rating) in [5, 5, 5, 4, 2].enumerated() {
            engine.ingest([cook("k\(i)", "r_s1", at: instant(Int64(10 + i)), rating: rating)])
        }
        let s = sentence(engine.profile(), "learned.like.ingredient.shrimp")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.evidence.numerator, 4)
        XCTAssertEqual(s?.evidence.denominator, 5)
        XCTAssertTrue(s?.text.contains("4 of the 5 shrimp recipes") ?? false, s?.text ?? "")
    }

    func testThinAndStaleEvidenceDoNotRender() {
        var engine = makeEngine()
        // Two cooks only: below the documented denominator of 3.
        engine.ingest([
            cook("k1", "r_s1", at: instant(1), rating: 5),
            cook("k2", "r_s1", at: instant(2), rating: 5),
        ])
        XCTAssertTrue(engine.profile().sentences.filter { $0.provenance == .learned }.isEmpty)

        // Five cooks, but the newest is 400 days old: past three half-lives.
        var stale = makeEngine()
        for i in 1...5 {
            stale.ingest([cook("k\(i)", "r_s\(i)", at: instant(-400), rating: 5)])
        }
        // A later event sets the clock so the cooks are genuinely old.
        stale.ingest([
            TasteEvent(
                id: EventID("now")!, at: instant(0), eater: nil, exposure: nil,
                kind: .viewed(recipe: RecipeID("r_c1")!)),
        ])
        XCTAssertTrue(stale.profile().sentences.filter { $0.provenance == .learned }.isEmpty)
    }

    // MARK: Edits change rankings immediately and predictably

    func testStatedSentenceReopenRemovesThePinAndTheSentence() {
        var engine = makeEngine()
        engine.ingest([
            cook("k1", "r_s1", at: instant(1), rating: 5),
            cook("k2", "r_s2", at: instant(1), rating: 5),
            cook("k3", "r_s3", at: instant(1), rating: 5),
            TasteEvent(
                id: EventID("p1")!, at: instant(2), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(
                    .setPreference(feature: FeatureKey(namespace: "ingredient", value: "shrimp"), polarity: .like))),
        ])
        let s = sentence(engine.profile(), "stated.ingredient.shrimp")
        XCTAssertNotNil(s)
        XCTAssertEqual(
            s?.edits.reopen,
            .clearPreference(feature: FeatureKey(namespace: "ingredient", value: "shrimp")))

        engine.ingest([
            TasteEvent(
                id: EventID("p2")!, at: instant(3), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(.clearPreference(feature: FeatureKey(namespace: "ingredient", value: "shrimp")))),
        ])
        XCTAssertNil(sentence(engine.profile(), "stated.ingredient.shrimp"), "reopened sentence disappears")
    }

    func testThisIsWrongOnALearnedSentenceDropsTheRecipe() throws {
        var engine = makeEngine()
        for i in 1...5 {
            engine.ingest([cook("k\(i)", "r_s\(i)", at: instant(1), rating: 5)])
        }
        let learned = try XCTUnwrap(sentence(engine.profile(), "learned.like.ingredient.shrimp"))
        let wrong = try XCTUnwrap(learned.edits.thisIsWrong, "learned sentences offer this-is-wrong")
        let candidates = [RecipeID("r_s1")!, RecipeID("r_c1")!, RecipeID("r_peanut")!]
        var rngBefore = SeededRNG(seed: 7)
        let before = engine.rank(
            RankInput(candidates: candidates, context: RankContext(explore: false)), rng: &rngBefore)
        XCTAssertEqual(before.first?.recipe.rawValue, "r_s1")

        // Applying the sentence's own edit op as a profile event.
        engine.ingest([
            TasteEvent(
                id: EventID("p1")!, at: instant(2), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(wrong)),
        ])
        var rngAfter = SeededRNG(seed: 7)
        let after = engine.rank(
            RankInput(candidates: candidates, context: RankContext(explore: false)), rng: &rngAfter)
        XCTAssertNotEqual(after.first?.recipe.rawValue, "r_s1", "the correction must drop shrimp immediately")
        // The learned sentence is replaced by the stated one.
        XCTAssertNil(sentence(engine.profile(), "learned.like.ingredient.shrimp"))
        XCTAssertNotNil(sentence(engine.profile(), "stated.ingredient.shrimp"))
    }

    // MARK: Don't-ask-again is soft and expires

    func testDontAskAgainHidesThenExpires() throws {
        var engine = makeEngine()
        engine.ingest([
            TasteEvent(
                id: EventID("p1")!, at: instant(0), eater: EaterID("sam")!, exposure: nil,
                kind: .profileEdit(.setNeverSuggest(ingredient: IngredientID("peanut_butter")!))),
        ])
        // While active: a sentence with the expiry date, and no peanut recipe.
        let s = try XCTUnwrap(sentence(engine.profile(), "neversuggest.ingredient.peanut_butter"))
        XCTAssertTrue(s.text.contains("expires on"), s.text)
        XCTAssertEqual(s.edits.reopen, .clearNeverSuggest(ingredient: IngredientID("peanut_butter")!))
        var rng = SeededRNG(seed: 7)
        let hidden = engine.rank(
            RankInput(candidates: [RecipeID("r_peanut")!, RecipeID("r_c1")!], context: RankContext(explore: false)),
            rng: &rng)
        XCTAssertFalse(hidden.contains { $0.recipe.rawValue == "r_peanut" })

        // After the 120-day horizon: the sentence and the block both lapse.
        engine.ingest([
            TasteEvent(
                id: EventID("v1")!, at: instant(121), eater: nil, exposure: nil,
                kind: .viewed(recipe: RecipeID("r_c1")!)),
        ])
        XCTAssertNil(
            sentence(engine.profile(), "neversuggest.ingredient.peanut_butter"), "expired requests stop rendering")
        var rng2 = SeededRNG(seed: 7)
        let unhidden = engine.rank(
            RankInput(candidates: [RecipeID("r_peanut")!, RecipeID("r_c1")!], context: RankContext(explore: false)),
            rng: &rng2)
        XCTAssertTrue(unhidden.contains { $0.recipe.rawValue == "r_peanut" })
    }

    // MARK: Restrictions render and reopen

    func testRestrictionSentenceRendersWithReopen() {
        var engine = makeEngine()
        let restriction = Restriction(kind: .allergy, target: "peanut_butter", source: "setup")
        engine.ingest([
            TasteEvent(
                id: EventID("p1")!, at: instant(0), eater: nil, exposure: nil,
                kind: .profileEdit(.setRestriction(restriction))),
        ])
        let s = sentence(engine.profile(), "restriction.allergy.peanut_butter")
        XCTAssertEqual(s?.text, "Allergy: peanut butter — always excluded.")
        XCTAssertEqual(s?.edits.reopen, .clearRestriction(restrictionKey: restriction))
        XCTAssertEqual(s?.provenance, .restriction)
    }

    // MARK: Determinism

    func testProfileIsDeterministicForStateAndClock() {
        var engine = makeEngine()
        for i in 1...5 {
            engine.ingest([
                cook("k\(i)", "r_c\(i)", at: instant(1), rating: 3),
                cook("l\(i)", "r_s\(i)", at: instant(1), rating: 5),
            ])
        }
        for i in 1...4 {
            engine.ingest([removed("x\(i)", "r_c\(i)", "cilantro", at: instant(2))])
        }
        XCTAssertEqual(engine.profile(), engine.profile())
    }
}
