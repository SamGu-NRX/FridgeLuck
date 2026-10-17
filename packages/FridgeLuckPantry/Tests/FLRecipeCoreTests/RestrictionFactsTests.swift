import XCTest
import FLDomain
import FLInventoryCore
import FLIngredientFacts
@testable import FLRecipeCore

/// Review round 2, part two: the seam against the REAL canonical dataset
/// (data/ingredient-facts) and the mapping units. The fixtures-based
/// regressions in PantryFeasibilityTests pin engine behavior with
/// deterministic facts; these pin the same behavior with the dataset the
/// product ships, plus the Restriction → FLRestrictions axis mapping.
final class RestrictionFactsTests: XCTestCase {
    /// The bundled dataset lives at <repo-root>/data/ingredient-facts;
    /// tests resolve it from the compile-time source path
    /// (Tests/FLRecipeCoreTests).
    private func canonicalStore() throws -> FLIngredientFactsStore {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let dataDirectory = here
            .appendingPathComponent("../../../..")
            .appendingPathComponent("data/ingredient-facts")
        return try FLIngredientFactsStore(dataDirectory: dataDirectory)
    }

    // MARK: The reviewer's examples, against the canonical dataset

    /// Cream cheese is a compound ingredient whose fact entry is complete
    /// and carries milk. The original check must block it for a milk-allergic
    /// household — the name-only check passed it.
    func testCanonicalFactsBlockCreamCheeseForMilkAllergy() throws {
        let creamCheese = RecipeFixtures.ingredient("cream cheese", fdc: 1017)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: creamCheese, grams: 200),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: creamCheese, grams: 1000),
            ]),
            restriction: try Restriction(allergens: [.milk]),
            facts: try canonicalStore(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .blockedByRestriction)
        XCTAssertEqual(report.outcome, .blocked)
    }

    /// Stock cube's fact entry is incomplete (flavourings vary by brand):
    /// milk is unknown. Even fully stocked, the line refuses to serve —
    /// needsConfirmation, not a pass.
    func testCanonicalFactsRefuseStockCubeForMilkAllergy() throws {
        let stockCube = RecipeFixtures.ingredient("stock cube", fdc: nil, local: 907)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: stockCube, grams: 50),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: stockCube, grams: 1000),
            ]),
            restriction: try Restriction(allergens: [.milk]),
            facts: try canonicalStore(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .needsConfirmation)
        XCTAssertNotEqual(report.outcome, .complete)
    }

    /// Positive control on the allergen axis: aioli's fact entry is a
    /// closed composition (garlic, olive oil, egg) with no milk source, so
    /// the store settles milk as free and the line proceeds to ordinary
    /// quantity logic — the fix must not over-block known-safe ingredients.
    func testCanonicalFactsAllowKnownFreeAllergenComposition() throws {
        let aioli = RecipeFixtures.ingredient("aioli", fdc: nil, local: 909)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: aioli, grams: 30),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: aioli, grams: 500),
            ]),
            restriction: try Restriction(allergens: [.milk]),
            facts: try canonicalStore(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.outcome, .complete)
    }

    /// Positive control on the diet axis: olive oil's entry settles vegan
    /// as allowed (a plant food), so a vegan household proceeds to ordinary
    /// quantity logic.
    func testCanonicalFactsAllowKnownFreeDietComposition() throws {
        let oliveOil = RecipeFixtures.ingredient("olive oil", fdc: 171413)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: oliveOil, grams: 60),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: oliveOil, grams: 1000),
            ]),
            restriction: try Restriction(dietExclusions: [.vegan]),
            facts: try canonicalStore(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.outcome, .complete)
    }

    /// The swap defect against the real dataset: a vegan household lacks
    /// tahini, and the accepted swap substitutes cream cheese — a dairy
    /// food. The swap is void; the line shops for a vegan alternative.
    /// (The original must itself be known-acceptable — a forbidden original
    /// is caught earlier, by the original-composition gate — and must not
    /// be an assumed staple.)
    func testCanonicalFactsRefuseSwapToKnownViolatingSubstitute() throws {
        let tahini = RecipeFixtures.ingredient("tahini", fdc: nil, local: 911)
        let creamCheese = RecipeFixtures.ingredient("cream cheese", fdc: 1017)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: tahini, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: creamCheese, grams: 10_000),
            ]),
            restriction: try Restriction(dietExclusions: [.vegan]),
            facts: try canonicalStore(),
            swaps: [
                try FLPantryFeasibility.FLAcceptedSwap(
                    replacesGroupKey: FLStockFold.groupKey(for: tahini),
                    substitute: creamCheese,
                    gramsFactor: 1.0
                )
            ],
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .missing)
        XCTAssertEqual(report.lines[0].viaSwap, false)
    }

    /// Allergen.gluten has no facts-allergen axis; the bridge routes it
    /// through the dataset's glutenFree diet axis. Tamari's wheat status is
    /// explicitly unknown in the dataset ("only a product ingredient
    /// declaration settles wheat") — so a wheat-allergic household gets a
    /// confirmation request for a tamari line, never a silent pass.
    func testCanonicalFactsRefuseTamariForGlutenAllergyThroughDietAxis() throws {
        let tamari = RecipeFixtures.ingredient("tamari", fdc: nil, local: 908)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: tamari, grams: 30),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: tamari, grams: 500),
            ]),
            restriction: try Restriction(allergens: [.gluten]),
            facts: try canonicalStore(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .needsConfirmation)
        XCTAssertNotEqual(report.outcome, .complete)
    }

    // MARK: The Restriction → FLRestrictions bridge

    func testBridgeMapsAllergensAndDietsToFactAxes() throws {
        let restriction = try Restriction(
            allergens: [.milk, .peanuts, .eggs, .shellfish, .sesame, .soy, .fish, .wheat, .treeNuts],
            dietExclusions: [.lactoseFree, .vegan, .vegetarian, .pescatarian]
        )
        let facts = restriction.factsRestrictions
        XCTAssertEqual(
            facts.allergens,
            [.milk, .peanuts, .egg, .crustaceanShellfish, .sesame, .soy, .fish, .wheat, .treeNuts]
        )
        XCTAssertEqual(facts.diets, [.dairyFree, .vegan, .vegetarian, .pescatarian])
    }

    func testBridgeRoutesGlutenThroughTheDietAxis() throws {
        let restriction = try Restriction(allergens: [.gluten])
        let facts = restriction.factsRestrictions
        XCTAssertTrue(facts.allergens.isEmpty, "the facts vocabulary has no gluten allergen axis")
        XCTAssertEqual(facts.diets, [.glutenFree])
    }

    /// halal, kosher, lowSodium, noPork and noAlcohol have no facts axis
    /// yet: the bridge maps nothing for them, and their enforcement stays
    /// with the name-based custom exclusions (recorded in the PR Handoff).
    func testBridgeLeavesUnfactoredDietAxesEmpty() throws {
        let restriction = try Restriction(
            dietExclusions: [.halal, .kosher, .lowSodium, .noPork, .noAlcohol]
        )
        let facts = restriction.factsRestrictions
        XCTAssertTrue(facts.allergens.isEmpty)
        XCTAssertTrue(facts.diets.isEmpty)
        XCTAssertTrue(restriction.excludes(canonicalName: "gelatin") == false, "unfactored axes are not silently name-based either")
    }

    // MARK: The verdict helper (shared by the original and swap checks)

    func testVerdictBlocksOnCustomExclusionBeforeFacts() throws {
        let restriction = try Restriction(customExclusions: ["butter"])
        let verdict = restrictionVerdict(
            restriction: restriction,
            facts: RecipeFixtures.round2Fixtures,
            canonicalName: "butter"
        )
        guard case .blocked = verdict else {
            return XCTFail("expected .blocked, got \(verdict)")
        }
    }

    func testVerdictBlocksOnKnownViolation() throws {
        let restriction = try Restriction(allergens: [.milk])
        let verdict = restrictionVerdict(
            restriction: restriction,
            facts: RecipeFixtures.round2Fixtures,
            canonicalName: "cream cheese"
        )
        guard case .blocked = verdict else {
            return XCTFail("expected .blocked, got \(verdict)")
        }
    }

    func testVerdictRefusesUnknownComposition() throws {
        let restriction = try Restriction(allergens: [.milk])
        let verdict = restrictionVerdict(
            restriction: restriction,
            facts: RecipeFixtures.allKnownEmpty,
            canonicalName: "stock cube"
        )
        guard case .needsConfirmation = verdict else {
            return XCTFail("expected .needsConfirmation, got \(verdict)")
        }
    }

    func testVerdictProceedsOnKnownAcceptableComposition() throws {
        let restriction = try Restriction(allergens: [.milk])
        let verdict = restrictionVerdict(
            restriction: restriction,
            facts: RecipeFixtures.round2Fixtures,
            canonicalName: "butter"
        )
        guard case .proceed = verdict else {
            return XCTFail("expected .proceed, got \(verdict)")
        }
    }

    func testVerdictProceedsWithEmptyRestrictionsEvenForUnknownComposition() throws {
        // There is no restriction question to fail: the gate binds the
        // household's restrictions, not ingredient knowledge in general.
        let restriction = try Restriction()
        let verdict = restrictionVerdict(
            restriction: restriction,
            facts: RecipeFixtures.allKnownEmpty,
            canonicalName: "unicorn berry"
        )
        guard case .proceed = verdict else {
            return XCTFail("expected .proceed, got \(verdict)")
        }
    }
}
