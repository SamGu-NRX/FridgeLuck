import XCTest
import FLDomain
import FLInventoryCore
@testable import FLRecipeCore

/// The feasibility contract (SPEC 3.2): five line states, no double counting,
/// unknown evidence never yields complete, garnish never blocks, restrictions
/// always do, and the fit line never overclaims.
final class PantryFeasibilityTests: XCTestCase {
    let flour = RecipeFixtures.ingredient("all-purpose flour", fdc: 168894)
    let milk = RecipeFixtures.ingredient("whole milk", fdc: 746778)
    let egg = RecipeFixtures.ingredient("egg", fdc: 748264)
    let parsley = RecipeFixtures.ingredient("parsley", fdc: 112978)
    let peanutButter = RecipeFixtures.ingredient("peanut butter", fdc: 172470)
    let chicken = RecipeFixtures.ingredient("chicken breast", fdc: 171077)

    func testCompleteWhenEveryRequiredLineIsCovered() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
                RecipeFixtures.purchase("p2", ingredient: milk, grams: 500),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.outcome, .complete)
        XCTAssertEqual(report.lines.map(\.state), [.satisfied, .satisfied])
        XCTAssertTrue(report.missingIngredients.isEmpty)
        XCTAssertEqual(report.fitLine, "2 of 2")
    }

    func testPartialNamesTheMissingIngredientsInOrder() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: milk, grams: 250),
            RecipeFixtures.makeLine("l3", ingredient: egg, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.outcome, .partial)
        // First appearance order: milk (line 2) before egg (line 3).
        XCTAssertEqual(report.missingIngredients.map(\.canonicalName), ["whole milk", "egg"])
        XCTAssertEqual(report.fitLine, "1 recorded · check whole milk and egg", report.fitLine)
        XCTAssertFalse(report.fitLine.lowercased().contains("can cook"), "a partial fit line never suggests cookability")
        XCTAssertFalse(report.fitLine.contains("%"), "a fit line never states a percentage")
    }

    func testShortLineReportsTheShortfall() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: milk, grams: 100)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .short)
        XCTAssertEqual(report.lines[0].availableGrams, 100)
        XCTAssertEqual(report.lines[0].requiredGrams, 250)
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.fitLine, "0 recorded · check whole milk", "the shortfall lives on the line's numbers, not in the fit line")
    }

    func testUnknownRecipeAmountNeverYieldsSatisfiedOrComplete() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: milk, grams: nil),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
                RecipeFixtures.purchase("p2", ingredient: milk, grams: 500),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.lines[1].state, .uncertainStock, "an unmeasured requirement is a decision the evidence cannot make")
        XCTAssertEqual(report.outcome, .partial, "unknown quantity evidence must block a complete claim")
        XCTAssertTrue(report.lines[1].reason.contains("unmeasured"), report.lines[1].reason)
        XCTAssertEqual(report.fitLine, "1 recorded · check whole milk")
    }

    func testUncountedShelfStockNeverYieldsSatisfiedOrComplete() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: nil, preparation: nil),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .uncertainStock, "present but uncounted stock is evidence of presence, not of sufficiency")
        XCTAssertNil(report.lines[0].availableGrams)
        XCTAssertEqual(report.lines[0].requiredGrams, 250)
        XCTAssertEqual(report.outcome, .partial)
    }

    func testZeroStockIsMissingNotShort() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        // Purchased and fully consumed: the item remains as a zero lot.
        let events = [
            RecipeFixtures.purchase("p1", ingredient: milk, grams: 100),
        ]
        let consumed = try FLStockEvent(
            id: "c1", commandID: "c1", householdID: try! FLHouseholdID("hh-test-1"),
            kind: .consumption, ingredient: milk,
            quantity: try QuantityEvidence.sourceGrams(GramMass(grams: 100)),
            source: .manual, timestamp: Date(timeIntervalSince1970: 1_760_000_060)
        )
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try FLStockFold.fold(events: events + [consumed]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .missing, "zero left is 'not on the shelf', not 'short'")
        XCTAssertEqual(report.lines[0].availableGrams, 0)
        XCTAssertEqual(report.outcome, .partial)
    }

    // MARK: No double counting

    func testSameIngredientOnTwoLinesDoesNotDoubleCountOneLot() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: flour, grams: 20),
        ])
        let enough = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: flour, grams: 320)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(enough.outcome, .complete, "310 g covers 300 + 20 only when the two lines do not each see the full shelf")

        let notEnough = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p2", ingredient: flour, grams: 310)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(notEnough.lines[0].state, .satisfied)
        XCTAssertEqual(notEnough.lines[1].state, .short, "the second line sees the remainder after the first line reserved")
        XCTAssertEqual(notEnough.lines[1].availableGrams, 10)
        XCTAssertEqual(notEnough.outcome, .partial)
    }

    func testAllocationOnlyDrawsFromLotsInTheUsableForm() throws {
        // Cooked chicken (older lot) cannot serve a raw line even though it
        // sits in the same identity group.
        let rawLine = try RecipeFixtures.makeLine("l1", ingredient: chicken, grams: 150, preparation: "chopped")
        let secondRawLine = try RecipeFixtures.makeLine("l2", ingredient: chicken, grams: 150, preparation: "chopped")
        let recipe = try RecipeFixtures.makeRecipe([rawLine, secondRawLine])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: chicken, grams: 200, preparation: "cooked"),
                RecipeFixtures.purchase("p2", ingredient: chicken, grams: 200),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.lines[1].state, .short, "only 200 g of raw stock exists; the cooked lot must not be silently consumed by a raw line")
        XCTAssertEqual(report.lines[1].availableGrams, 50)
    }

    // MARK: Optional garnish

    func testMissingGarnishNeverBlocksCompleteness() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: parsley, grams: 10, isOptionalGarnish: true),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.outcome, .complete, "optional garnish is not required")
        XCTAssertEqual(report.garnishLines.count, 1)
        XCTAssertEqual(report.garnishLines[0].state, .missing, "tracked and shown, never required")
        XCTAssertEqual(report.lines.count, 1, "garnish lines stay out of the required bill")
    }

    func testGarnishIsJudgedAgainstTheRemainderWithoutReserving() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: flour, grams: 20, isOptionalGarnish: true),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: flour, grams: 310)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.garnishLines[0].state, .short, "the garnish sees the 10 g the required line left")
        XCTAssertEqual(report.outcome, .complete, "garnish state never changes the outcome")
    }

    // MARK: Hard restrictions

    func testRestrictedRequiredIngredientBlocksTheRecipe() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: peanutButter, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
                RecipeFixtures.purchase("p2", ingredient: peanutButter, grams: 500),
            ]),
            restriction: try Restriction(customExclusions: ["peanut butter"]),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.outcome, .blocked)
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.lines[1].state, .blockedByRestriction, "stock is irrelevant for a forbidden ingredient")
        XCTAssertEqual(report.fitLine, "Blocked — peanut butter is excluded by this household's hard restrictions.")
    }

    func testRestrictedIngredientIsBlockedEvenWithNoStock() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: peanutButter, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: [],
            restriction: try Restriction(customExclusions: ["peanut butter"]),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .blockedByRestriction, "the restriction is judged before the shelf")
        XCTAssertEqual(report.outcome, .blocked)
    }

    func testRestrictedGarnishDoesNotBlock() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: peanutButter, grams: 10, isOptionalGarnish: true),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000)]),
            restriction: try Restriction(customExclusions: ["peanut butter"]),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.outcome, .complete, "a forbidden garnish is shown as forbidden, not allowed to block dinner")
        XCTAssertEqual(report.garnishLines[0].state, .blockedByRestriction)
    }

    // MARK: Report integrity

    func testReportOutcomeDerivationIsEnforced() throws {
        let line = try FLFeasibilityLine(
            lineID: "l1", state: .uncertainStock, ingredient: milk,
            availableGrams: nil, requiredGrams: nil, reason: "uncounted"
        )
        RecipeFixtures.expectRefusal(.validation(
            target: "FLFeasibilityReport.outcome",
            reason: "outcome 'complete' does not follow from the line states (expected 'partial')"
        )) {
            try FLFeasibilityReport(
                recipeKey: RecipeKey(source: .user, sourceRecipeID: "x", revision: 1),
                outcome: .complete, lines: [line], garnishLines: [], fitLine: "x"
            )
        }
    }

    func testMissingIngredientsDeduplicateByIdentityInFirstAppearanceOrder() throws {
        let localMilk = RecipeFixtures.ingredient("whole milk", local: 42)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
            RecipeFixtures.makeLine("l2", ingredient: localMilk, grams: 30),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe, stock: [], restriction: Restriction(), facts: RecipeFixtures.allKnownEmpty
        )
        // fdc:746778 and local:42 are distinct identities — both listed, order preserved.
        XCTAssertEqual(report.missingIngredients.count, 2)
        XCTAssertEqual(report.missingIngredients[0].canonicalName, "whole milk")
    }

    func testReportCodableRoundTripIsCanonical() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: milk, grams: 100)]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        let data = try FLJSON.canonicalData(report)
        let decoded = try FLJSON.canonicalDecoder().decode(FLFeasibilityReport.self, from: data)
        XCTAssertEqual(decoded, report)

        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"outcome\" : \"partial\""), "canonical wire shape changed: \(raw)")
        XCTAssertTrue(raw.contains("\"state\" : \"short\""), "canonical wire shape changed: \(raw)")
    }

    // MARK: Review round 2 — composition truth fails closed

    /// A milk-allergic household must not be served a complete cream-cheese
    /// recipe: the original check now takes the allergen facts, and a known
    /// violation blocks, exactly like a named exclusion.
    func testOriginalCheckRefusesKnownAllergenComposition() throws {
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
            facts: RecipeFixtures.round2Fixtures,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .blockedByRestriction)
        XCTAssertEqual(report.lines[0].availableGrams, nil, "a refused line reserves nothing")
        XCTAssertEqual(report.outcome, .blocked)
    }

    /// Same defect class on the diet axis: cream cheese fails vegan, so a
    /// vegan household sees the line blocked, not silently served.
    func testOriginalCheckRefusesKnownDietComposition() throws {
        let creamCheese = RecipeFixtures.ingredient("cream cheese", fdc: 1017)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: creamCheese, grams: 200),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: creamCheese, grams: 1000),
            ]),
            restriction: try Restriction(dietExclusions: [.vegan]),
            facts: RecipeFixtures.round2Fixtures,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .blockedByRestriction)
        XCTAssertEqual(report.outcome, .blocked)
    }

    /// An ingredient whose composition the facts source cannot decide is a
    /// refusal (needsConfirmation), never a pass — even fully stocked.
    func testUnknownCompositionBecomesNeedsConfirmationNotAPass() throws {
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
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .needsConfirmation)
        XCTAssertEqual(report.lines[0].availableGrams, nil, "an undecided line reserves nothing")
        XCTAssertNotEqual(report.outcome, .complete)
        XCTAssertEqual(report.missingIngredients.map { FLStockFold.groupKey(for: $0) }, [FLStockFold.groupKey(for: stockCube)], "an unresolved line is listed among the unmet ingredients")
    }

    /// A vegan household lacks tahini; the accepted swap substitutes cream
    /// cheese — a dairy food the facts source knows. The swap is void; the
    /// line reports missing and shops for a vegan alternative. (The
    /// original must itself be known-acceptable — a forbidden original is
    /// caught earlier, by the original-composition gate — and must not be
    /// an assumed staple, or the refused swap would resolve as assumed
    /// instead of missing.)
    func testSwapRefusesSubstituteWithKnownViolatedDiet() throws {
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
            facts: RecipeFixtures.round2Fixtures,
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
        XCTAssertEqual(report.outcome, .partial)
    }

    /// The stale-rescue pattern applied to composition: a missing line whose
    /// only rescue is a stocked-but-unknown substitute downgrades to
    /// needsConfirmation — nothing is reserved, nothing is claimed.
    func testSwapToUnknownCompositionDowngradesToNeedsConfirmation() throws {
        let oliveOil = RecipeFixtures.ingredient("olive oil", fdc: 171413)
        let stockCube = RecipeFixtures.ingredient("stock cube", fdc: nil, local: 907)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: oliveOil, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: stockCube, grams: 10_000),
            ]),
            restriction: try Restriction(allergens: [.milk]),
            facts: RecipeFixtures.round2Fixtures,
            swaps: [
                try FLPantryFeasibility.FLAcceptedSwap(
                    replacesGroupKey: FLStockFold.groupKey(for: oliveOil),
                    substitute: stockCube,
                    gramsFactor: 1.0
                )
            ],
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .needsConfirmation)
        XCTAssertEqual(report.lines[0].viaSwap, false)
        XCTAssertTrue(report.lines[0].reason.contains("stock cube"), "the reason names the undecided substitute: \(report.lines[0].reason)")
        XCTAssertEqual(report.outcome, .partial)
    }

    /// The fail-closed gate answers the household's restriction question;
    /// with no restrictions there is nothing to fail, and an unfactored
    /// ingredient proceeds to ordinary quantity logic.
    func testUnfactoredIngredientWithNoRestrictionsStillEvaluates() throws {
        let exotic = RecipeFixtures.ingredient("unicorn berry", fdc: nil, local: 999)
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: exotic, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: exotic, grams: 500),
            ]),
            restriction: Restriction(),
            facts: RecipeFixtures.allKnownEmpty,
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.outcome, .complete)
    }
}
