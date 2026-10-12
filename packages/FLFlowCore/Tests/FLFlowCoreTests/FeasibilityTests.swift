import XCTest
@testable import FLFlowCore
import FLDomain

/// The five line states of SPEC 3.2 and the allocation rules around them:
/// repeated lines summed, garnish separate, stock reserved across a plan,
/// unknown evidence surfaced as unknown and never guessed.
final class FeasibilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)  // fixed reference time

    private func pantry(_ lines: [FlowPantryLine], staples: Set<String> = []) -> PantryView {
        let policy = try! PantryPolicy(stapleNames: staples, stalenessHorizonSeconds: 14 * 24 * 3600)
        return PantryView(lines: lines, policy: policy, now: t0)
    }

    // MARK: Line states

    func testSufficientWhenStockCoversDemand() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(200)),
        ])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(500), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.count, 1)
        XCTAssertEqual(result.lineFits.first?.state, .sufficient)
        XCTAssertTrue(result.isReady)
    }

    func testShortCarriesRequestedAndAvailableAmounts() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(400)),
        ])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(150), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .short(requestedGrams: 400, availableGrams: 150))
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.checkNames, ["rice"])
    }

    func testMissingIngredientIsShortWithZeroAvailable() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "feta", TestBuilders.grams(100)),
        ])
        let view = pantry([])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .short(requestedGrams: 100, availableGrams: 0))
    }

    func testUnknownPantryQuantityStaysUnknownNeverGuessed() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "eggs", TestBuilders.grams(200)),
        ])
        // A confident shelf scan that could not measure the eggs is still unknown.
        let view = pantry([TestBuilders.pantryLine("eggs", .unknown, confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .quantityUnknown)
        XCTAssertFalse(result.isReady)
    }

    func testUnknownRecipeQuantityStaysUnknown() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "eggs", .unknown),
        ])
        let view = pantry([TestBuilders.pantryLine("eggs", TestBuilders.grams(500), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .quantityUnknown)
        XCTAssertNil(result.lineFits.first?.requestedGrams)
    }

    func testStaleEvidenceNeedsReconfirming() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "milk", TestBuilders.grams(250)),
        ])
        let oldConfirmation = t0.addingTimeInterval(-30 * 24 * 3600)
        let view = pantry([TestBuilders.pantryLine("milk", TestBuilders.grams(1000), confirmedAt: oldConfirmation)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .needsReconfirming(lastConfirmedAt: oldConfirmation))
        XCTAssertFalse(result.isReady)
    }

    func testNeverConfirmedEvidenceNeedsReconfirming() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "milk", TestBuilders.grams(250)),
        ])
        let view = pantry([TestBuilders.pantryLine("milk", TestBuilders.grams(1000), confirmedAt: nil)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .needsReconfirming(lastConfirmedAt: nil))
    }

    func testAssumedStapleIsAssumedNeverSufficient() throws {
        // SPEC 3.2 (review round 2, blocker 2): an assumed staple backs a
        // line ONLY as an assumption. The line keeps its own state, never
        // reports sufficient, never claims ready, is not counted present,
        // and is named in the check prompts so the cook confirms it.
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "salt", TestBuilders.grams(5)),
        ])
        let view = pantry([], staples: ["salt"])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.state, .assumedStaple)
        XCTAssertFalse(result.isReady, "assumed is never sufficient: the candidate is not ready")
        XCTAssertEqual(result.sufficientCount, 0, "only evidence-backed lines count as sufficient")
        XCTAssertEqual(result.presentCount, 0, "an assumed staple has no shelf evidence at all")
        XCTAssertEqual(result.checkNames, ["salt"], "the assumption becomes a check prompt")
    }

    // MARK: Summation, garnish, servings

    func testRepeatedLinesAreSummed() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "olive oil", TestBuilders.grams(30)),
            TestBuilders.line("l2", "olive oil", TestBuilders.grams(45)),
        ])
        let view = pantry([TestBuilders.pantryLine("olive oil", TestBuilders.grams(80), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        // 30 + 45 = 75 <= 80: one summed demand, sufficient.
        XCTAssertEqual(result.lineFits.count, 1)
        XCTAssertEqual(result.lineFits.first?.state, .sufficient)
        XCTAssertEqual(result.lineFits.first?.requestedGrams, 75)
    }

    func testOptionalGarnishIsSeparateFromFeasibility() throws {
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "rice", TestBuilders.grams(200)),
            TestBuilders.line("l2", "parsley", TestBuilders.grams(10), garnish: true),
        ])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(500), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.requiredCount, 1, "garnish is tracked, never required")
        XCTAssertTrue(result.isReady)
        XCTAssertFalse(result.checkNames.contains("parsley"))
    }

    func testHouseholdMeasureConvertsWithItsEvidence() throws {
        // 1 cup whole milk = 244 g (USDA FNDDS) — the conversion travels with
        // the line as evidence.
        let revision = TestBuilders.revision("a", lines: [
            TestBuilders.line("l1", "whole milk", .householdMeasure(
                try! HouseholdMeasure(amount: 1, unit: "cup", gramsPerUnit: 244, conversionSource: "USDA FNDDS")
            )),
        ])
        let view = pantry([TestBuilders.pantryLine("whole milk", TestBuilders.grams(300), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let result = try FeasibilityEngine.evaluate(revision: revision, servings: 2, pantry: view, ledger: ledger)
        XCTAssertEqual(result.lineFits.first?.requestedGrams, 244)
        XCTAssertEqual(result.lineFits.first?.state, .sufficient)
    }

    // MARK: Plan reservation

    func testReservationCarriesAcrossTwoDinnersWithoutDoubleCounting() throws {
        let rice200 = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(300), confirmedAt: t0)])

        // Dinner 1 reserves 200 g.
        var ledger = StockLedger(pantry: view)
        let first = try FeasibilityEngine.evaluateAndReserve(revision: rice200, servings: 2, pantry: view, ledger: &ledger)
        XCTAssertTrue(first.isReady)

        // Dinner 2 sees the remaining 100 g and reports the honest shortfall.
        let second = try FeasibilityEngine.evaluateAndReserve(revision: rice200, servings: 2, pantry: view, ledger: &ledger)
        XCTAssertEqual(second.lineFits.first?.state, .short(requestedGrams: 200, availableGrams: 100))
        XCTAssertFalse(second.isReady)
    }

    func testFailedAllocationLeavesLedgerUntouched() throws {
        let rice200 = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))])
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(100), confirmedAt: t0)])
        var ledger = StockLedger(pantry: view)
        _ = try FeasibilityEngine.evaluateAndReserve(revision: rice200, servings: 2, pantry: view, ledger: &ledger)
        // The short evaluation must not have consumed anything.
        guard case let .known(remaining)? = ledger.entry(for: "rice") else {
            return XCTFail("expected known stock")
        }
        XCTAssertEqual(remaining.grams, 100, "a failed allocation must not corrupt the ledger")
    }

    func testUnknownStockIsNeverConsumedByKnownDemand() throws {
        let eggs100 = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "eggs", TestBuilders.grams(100))])
        let view = pantry([TestBuilders.pantryLine("eggs", .unknown, confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        var mutable = ledger
        let result = try FeasibilityEngine.evaluateAndReserve(revision: eggs100, servings: 2, pantry: view, ledger: &mutable)
        XCTAssertEqual(result.lineFits.first?.state, .quantityUnknown)
        guard case .unknown? = mutable.entry(for: "eggs") else {
            return XCTFail("unknown stock must stay unknown")
        }
    }

    // MARK: Servings scaling

    func testServingsScaleTheDemandLinearly() throws {
        let revision = TestBuilders.revision("a", lines: [TestBuilders.line("l1", "rice", TestBuilders.grams(200))], basisServings: 2)
        let view = pantry([TestBuilders.pantryLine("rice", TestBuilders.grams(1000), confirmedAt: t0)])
        let ledger = StockLedger(pantry: view)
        let for4 = try FeasibilityEngine.evaluate(revision: revision, servings: 4, pantry: view, ledger: ledger)
        XCTAssertEqual(for4.lineFits.first?.requestedGrams, 400, "quantities scale with evidence, never invented")
    }
}
