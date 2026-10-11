import XCTest
import FLDomain
import FLInventoryCore
@testable import FLRecipeCore

/// SPEC 3.2 contract tests for the parts of the fit the first checkpoint
/// did not cover: servings scaling, the assumed-staple and needs-reconfirming
/// states, accepted swaps, and the SPEC's exact fit-line templates.
/// All evaluations pass explicit dates so the audit stays deterministic.
final class FeasibilityContractTests: XCTestCase {
    // The fixtures' fixed epoch: 2025-10-09 05:23:20 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    let flour = RecipeFixtures.ingredient("all-purpose flour", fdc: 168894)
    let milk = RecipeFixtures.ingredient("whole milk", fdc: 746778)
    let egg = RecipeFixtures.ingredient("egg", fdc: 748264)
    let parsley = RecipeFixtures.ingredient("parsley", fdc: 112978)
    let butter = RecipeFixtures.ingredient("butter", fdc: 173430)
    let margarine = RecipeFixtures.ingredient("margarine", fdc: 171714)
    let salt = RecipeFixtures.ingredient("salt", fdc: nil, local: 9001)

    // MARK: Servings (SPEC 3.2: "for the chosen recipe revision, servings")

    func testTargetServingsScaleTheRequiredBill() throws {
        // The revision's basis is 2 servings (fixture default); asking for
        // 4 doubles every line. Milk is covered at 2 but short at 4.
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: milk, grams: 250),
        ])
        let stock = try RecipeFixtures.stock([
            RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
            RecipeFixtures.purchase("p2", ingredient: milk, grams: 400),
        ])
        let doubled = try FLPantryFeasibility.evaluate(
            recipe: recipe, stock: stock, restriction: Restriction(), targetServings: 4,
            reconfirmWindow: nil
        )
        XCTAssertEqual(doubled.lines[0].requiredGrams, 600)
        XCTAssertEqual(doubled.lines[1].requiredGrams, 500)
        XCTAssertEqual(doubled.lines[0].state, .satisfied)
        XCTAssertEqual(doubled.lines[1].state, .short, "scaling moves a covered line to short when the shelf cannot follow")
        XCTAssertEqual(doubled.outcome, .partial)

        let basis = try FLPantryFeasibility.evaluate(
            recipe: recipe, stock: stock, restriction: Restriction(), targetServings: 2,
            reconfirmWindow: nil
        )
        XCTAssertEqual(basis.lines.map(\.state), [.satisfied, .satisfied])
        XCTAssertEqual(basis.outcome, .complete)
    }

    func testNilTargetServingsMeansTheRecipeBasis() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: milk, grams: 300)]),
            restriction: Restriction(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].requiredGrams, 250, "no target means the basis, unscaled")
        XCTAssertEqual(report.lines[0].state, .satisfied)
    }

    // MARK: Assumed staple (SPEC 3.2 state 4)

    func testStapleWithNoRecordIsAssumedNotMissing() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: salt, grams: 5),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe, stock: [], restriction: Restriction()
        )
        XCTAssertEqual(report.lines[0].state, .assumedStaple)
        XCTAssertEqual(report.outcome, .partial, "an assumption is not evidence; the recipe is not complete on it")
        XCTAssertEqual(report.fitLine, "0 recorded · check salt")
    }

    func testStapleAssumptionNeverOverridesRecordedStock() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: salt, grams: 5),
        ])
        // Real stock decides on the normal states.
        let stocked = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: salt, grams: 50)]),
            restriction: Restriction(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(stocked.lines[0].state, .satisfied)

        // A recorded empty jar is evidence of absence, not an invitation
        // to assume: the user said the salt ran out.
        let emptied = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: salt, grams: 50), RecipeFixtures.consume("c1", ingredient: salt, grams: 50, timestamp: Self.t0)]),
            restriction: Restriction(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(emptied.lines[0].state, .missing, "a recorded empty is a shopping trip, not an assumption")
    }

    func testRestrictionsBeatTheStapleAssumption() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: salt, grams: 5),
        ])
        let restriction = try Restriction(customExclusions: ["salt"])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe, stock: [], restriction: restriction
        )
        XCTAssertEqual(report.lines[0].state, .blockedByRestriction, "food safety outranks the staple assumption")
        XCTAssertEqual(report.outcome, .blocked)
    }

    // MARK: Stale evidence (SPEC 3.2 state 5: "needs reconfirming")

    func testStaleEvidenceNeedsReconfirming() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: 500, timestamp: Self.t0),
            ]),
            restriction: Restriction(),
            now: Self.t0.addingTimeInterval(20 * Self.day),
            reconfirmWindow: 14 * Self.day
        )
        XCTAssertEqual(report.lines[0].state, .needsReconfirming, "evidence older than the window asks the cook to look")
        XCTAssertEqual(report.lines[0].availableGrams, 500, "the numbers stay known; only freshness is in question")
        XCTAssertEqual(report.lines[0].requiredGrams, 250)
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.fitLine, "0 recorded · check whole milk")
    }

    func testFreshConfirmationClearsStaleness() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: 500, timestamp: Self.t0),
                RecipeFixtures.purchase("p2", ingredient: milk, grams: 100, timestamp: Self.t0.addingTimeInterval(19 * Self.day)),
            ]),
            restriction: Restriction(),
            now: Self.t0.addingTimeInterval(20 * Self.day),
            reconfirmWindow: 14 * Self.day
        )
        XCTAssertEqual(report.lines[0].state, .satisfied, "a recent confirmation of the shelf is fresh evidence")
    }

    func testAScanRefreshesOnlyWhatItSaw() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
            RecipeFixtures.makeLine("l2", ingredient: egg, grams: 100),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: 500, timestamp: Self.t0.addingTimeInterval(19 * Self.day)),
                RecipeFixtures.purchase("p2", ingredient: egg, grams: 300, timestamp: Self.t0),
            ]),
            restriction: Restriction(),
            now: Self.t0.addingTimeInterval(20 * Self.day),
            reconfirmWindow: 14 * Self.day
        )
        XCTAssertEqual(report.lines[0].state, .satisfied, "the scanned shelf item is fresh")
        XCTAssertEqual(report.lines[1].state, .needsReconfirming, "the unscanned item keeps its stale evidence — a scan refreshes only what it saw")
    }

    func testNilReconfirmWindowNeverStales() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: 500, timestamp: Self.t0),
            ]),
            restriction: Restriction(),
            now: Self.t0.addingTimeInterval(365 * Self.day),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied, "staleness checking is a policy; nil disables it")
    }

    // MARK: Accepted swaps (SPEC 3.2: "servings and accepted swaps")

    func testAcceptedSwapRescuesAMissingLine() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: butter, grams: 100),
        ])
        let swap = try FLPantryFeasibility.FLAcceptedSwap(replacesGroupKey: FLStockFold.groupKey(for: butter), substitute: margarine, gramsFactor: 1.0)
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: margarine, grams: 200)]),
            restriction: Restriction(),
            swaps: [swap],
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied, "the accepted substitute's stock covers the line")
        XCTAssertEqual(report.lines[0].viaSwap, true)
        XCTAssertEqual(report.lines[0].availableGrams, 200)
        XCTAssertEqual(report.outcome, .complete)
        XCTAssertEqual(report.fitLine, "0 of 1 · 1 swap", "the numerator counts stock-satisfied lines; swaps are the suffix")
    }

    func testSwapFactorScalesTheSubstituteGrams() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: butter, grams: 100),
        ])
        let swap = try FLPantryFeasibility.FLAcceptedSwap(replacesGroupKey: FLStockFold.groupKey(for: butter), substitute: margarine, gramsFactor: 0.5)
        let covered = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: margarine, grams: 60)]),
            restriction: Restriction(),
            swaps: [swap],
            reconfirmWindow: nil
        )
        XCTAssertEqual(covered.lines[0].state, .satisfied, "100 g asked at factor 0.5 needs 50 g of substitute")
        XCTAssertEqual(covered.lines[0].viaSwap, true)

        let short = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: margarine, grams: 40)]),
            restriction: Restriction(),
            swaps: [swap],
            reconfirmWindow: nil
        )
        XCTAssertEqual(short.lines[0].state, .missing, "a substitute that cannot cover the line never rescues it")
        XCTAssertEqual(short.lines[0].viaSwap, false)
    }

    func testSwapNeverRescuesWhenTheSubstituteIsRestricted() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: butter, grams: 100),
        ])
        let swap = try FLPantryFeasibility.FLAcceptedSwap(replacesGroupKey: FLStockFold.groupKey(for: butter), substitute: margarine, gramsFactor: 1.0)
        let restriction = try Restriction(customExclusions: ["margarine"])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: margarine, grams: 200)]),
            restriction: restriction,
            swaps: [swap]
        )
        XCTAssertEqual(report.lines[0].state, .missing, "a restricted substitute would feed the household a forbidden food; the swap is void")
        XCTAssertEqual(report.lines[0].viaSwap, false)
    }

    func testSwappedLineKeepsTheStalenessOfTheSubstituteLot() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: butter, grams: 100),
        ])
        let swap = try FLPantryFeasibility.FLAcceptedSwap(replacesGroupKey: FLStockFold.groupKey(for: butter), substitute: margarine, gramsFactor: 1.0)
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([RecipeFixtures.purchase("p1", ingredient: margarine, grams: 200, timestamp: Self.t0)]),
            restriction: Restriction(),
            swaps: [swap],
            now: Self.t0.addingTimeInterval(20 * Self.day),
            reconfirmWindow: 14 * Self.day
        )
        XCTAssertEqual(report.lines[0].state, .needsReconfirming, "the substitute's evidence is what the line stands on")
        XCTAssertEqual(report.lines[0].viaSwap, false, "swap attribution only attaches to satisfied lines")
    }

    // MARK: Fit-line templates (SPEC 3.2)

    func testFitLineCountsStockSatisfiedLinesAndSwaps() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: flour, grams: 300),
            RecipeFixtures.makeLine("l2", ingredient: milk, grams: 250),
        ])
        let swap = try FLPantryFeasibility.FLAcceptedSwap(replacesGroupKey: FLStockFold.groupKey(for: milk), substitute: margarine, gramsFactor: 1.0)
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: flour, grams: 1000),
                RecipeFixtures.purchase("p2", ingredient: margarine, grams: 500),
            ]),
            restriction: Restriction(),
            swaps: [swap],
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.lines[0].state, .satisfied)
        XCTAssertEqual(report.lines[1].state, .satisfied)
        XCTAssertEqual(report.lines[1].viaSwap, true)
        XCTAssertEqual(report.fitLine, "1 of 2 · 1 swap", "nine-of-ten style attribution: stock-satisfied count, then swaps")
    }

    func testFitLineNamesUpToThreeProblemsInBillOrder() throws {
        let recipe = try RecipeFixtures.makeRecipe([
            RecipeFixtures.makeLine("l1", ingredient: milk, grams: 250),   // short: 100 of 250
            RecipeFixtures.makeLine("l2", ingredient: egg, grams: 100),    // missing
            RecipeFixtures.makeLine("l3", ingredient: flour, grams: nil),  // unmeasured requirement
            RecipeFixtures.makeLine("l4", ingredient: parsley, grams: 20), // satisfied: 1000 g
        ])
        let report = try FLPantryFeasibility.evaluate(
            recipe: recipe,
            stock: try RecipeFixtures.stock([
                RecipeFixtures.purchase("p1", ingredient: milk, grams: 100),
                RecipeFixtures.purchase("p4", ingredient: parsley, grams: 1000),
            ]),
            restriction: Restriction(),
            reconfirmWindow: nil
        )
        XCTAssertEqual(report.fitLine, "1 recorded · check whole milk, egg and all-purpose flour")
    }
}
