import XCTest
@testable import FLKitchenKnowledge

/// Waste-math tests use literal expected values hand-computed against the
/// semantics in data/kitchen-knowledge/waste/model.md. When Part 2's twenty
/// hand-computed examples land, they are asserted here verbatim (see the join
/// checklist in data/kitchen-knowledge/SCHEMA.md).
final class WasteMathTests: XCTestCase {
    private func price(_ key: String, _ usdPerKg: Double) -> PriceFactor {
        PriceFactor(
            ingredientKey: key, usdPerKg: usdPerKg,
            displayQuantity: nil, displayPriceUsd: nil, sourceSeries: nil, citationId: "t1"
        )
    }

    private func emission(_ key: String, _ low: Double, _ central: Double, _ high: Double) -> EmissionFactor {
        EmissionFactor(
            ingredientKey: key, owidEntity: nil,
            kgCo2ePerKg: Range3(low: low, central: central, high: high), citationId: "t2"
        )
    }

    func testDiscardPricesAndEmissionsWithUncertainty() throws {
        // 1000 g beef discarded. $11.00/kg; 59.6 (low 50.0, high 70.0) kg CO2e/kg.
        var ledger = WasteLedger(prices: [price("beef", 11.0)], emissions: [emission("beef", 50.0, 59.6, 70.0)])
        ledger.record(KitchenEvent(kind: .add, ingredientKey: "beef", grams: 1000))
        ledger.record(KitchenEvent(
            kind: .discard, ingredientKey: "beef", grams: 1000,
            on: "2026-10-10", lotUseBy: "2026-10-05"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.wasted.grams, 1000.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), 11.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), 59.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.low), 50.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.high), 70.0, accuracy: 0.0001)
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.notCounted.grams, 1000.0, "add events are corrections, not outcomes")
        XCTAssertNil(result.notCounted.moneyUsd)
    }

    func testConsumeBeforeUseByCountsAsSaved() throws {
        // 450 g rice consumed 2026-10-09 with use-by 2026-10-12: saved.
        // $1.30/kg -> 0.45 kg x 1.30 = 0.585 -> $0.59 at output.
        // 4.0 kg CO2e/kg point estimate -> 1.8.
        var ledger = WasteLedger(prices: [price("rice", 1.30)], emissions: [emission("rice", 4.0, 4.0, 4.0)])
        ledger.record(KitchenEvent(kind: .add, ingredientKey: "rice", grams: 1000))
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "rice", grams: 450,
            on: "2026-10-09", lotUseBy: "2026-10-12"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.saved.grams, 450.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.saved.moneyUsd), 0.59, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.saved.kgCo2e?.central), 1.8, accuracy: 0.0001)
        XCTAssertEqual(result.usedLate.grams, 0.0, accuracy: 0.001)
    }

    func testConsumeOnUseByDayStillCountsAsSaved() {
        // Use-by dates are inclusive: same-day consumption is still saved.
        var ledger = WasteLedger(prices: [price("milk", 0.90)], emissions: [emission("milk", 1.4, 1.4, 1.4)])
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "milk", grams: 250,
            on: "2026-10-12", lotUseBy: "2026-10-12"
        ))

        XCTAssertEqual(ledger.result().saved.grams, 250.0, accuracy: 0.001)
    }

    func testConsumeAfterUseByIsUsedLateNeverSaved() throws {
        // Sam's copy rule: food eaten after its use-by is food used late,
        // not food saved.
        var ledger = WasteLedger(prices: [price("yogurt", 2.0)], emissions: [emission("yogurt", 1.3, 1.3, 1.3)])
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "yogurt", grams: 200,
            on: "2026-10-10", lotUseBy: "2026-10-05"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.usedLate.grams, 200.0, accuracy: 0.001)
        XCTAssertEqual(result.saved.grams, 0.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.usedLate.moneyUsd), 0.4, accuracy: 0.0001)
    }

    func testConsumeWithoutUseByEvidenceIsUnknownNotSaved() {
        var ledger = WasteLedger(prices: [price("pasta", 1.5)], emissions: [emission("pasta", 1.8, 1.8, 1.8)])
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "pasta", grams: 120, on: "2026-10-10"))
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "pasta", grams: 80,
            lotUseBy: "2026-10-11" // no event date -> cannot compare
        ))

        let result = ledger.result()
        XCTAssertEqual(result.consumedUnknown.grams, 200.0, accuracy: 0.001)
        XCTAssertEqual(result.saved.grams, 0.0, accuracy: 0.001)
    }

    func testAggregationAcrossIngredientsSumsUnroundedThenRounds() throws {
        // 300 g rice ($2.00/kg, 4.0) + 700 g beans ($3.00/kg, 2.0), both wasted.
        var ledger = WasteLedger(
            prices: [price("rice", 2.0), price("beans", 3.0)],
            emissions: [emission("rice", 4.0, 4.0, 4.0), emission("beans", 2.0, 2.0, 2.0)]
        )
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "rice", grams: 300, on: "2026-10-10"))
        ledger.record(KitchenEvent(kind: .expire, ingredientKey: "beans", grams: 700, on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(result.wasted.grams, 1000.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), 2.7, accuracy: 0.0001) // 0.6 + 2.1
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), 2.6, accuracy: 0.0001) // 1.2 + 1.4
    }

    func testRoundingBoundaryCase() throws {
        // 123.5 g at $1.25/kg: 0.1235 kg x 1.25 = 0.154375 -> $0.15.
        // 123.5 g at 0.333 kg CO2e/kg: 0.1235 x 0.333 = 0.0411205 -> 0.041.
        var ledger = WasteLedger(prices: [price("tofu", 1.25)], emissions: [emission("tofu", 0.333, 0.333, 0.333)])
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "tofu", grams: 123.5, on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), 0.15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), 0.041, accuracy: 0.0001)
        XCTAssertEqual(result.wasted.grams, 123.5, accuracy: 0.001)
    }

    func testDroppedEventCounterForNonPositiveGrams() {
        var ledger = WasteLedger()
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "rice", grams: 0))
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "rice", grams: -5))
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "rice", grams: 100, on: "2026-10-10"))
        XCTAssertEqual(ledger.droppedEventCount, 2)
        XCTAssertEqual(ledger.result().wasted.grams, 100.0, accuracy: 0.001)
    }

    func testEmptyLedgerProducesZeroResult() {
        let result = WasteLedger().result()
        XCTAssertEqual(result.saved.grams, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.wasted.grams, 0.0, accuracy: 0.001)
        XCTAssertNil(result.saved.moneyUsd)
        XCTAssertNil(result.saved.kgCo2e)
        XCTAssertTrue(result.refusals.isEmpty)
    }
}
