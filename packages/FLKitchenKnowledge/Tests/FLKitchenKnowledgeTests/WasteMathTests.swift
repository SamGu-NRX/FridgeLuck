import XCTest
@testable import FLKitchenKnowledge

/// Waste-math tests use literal expected values hand-computed against the
/// semantics in data/kitchen-knowledge/waste/model.md. Comparisons are exact
/// decimal equalities: the ledger computes in Decimal and rounds half-up once
/// at output, so there is no tolerance to hide a rounding defect behind.
/// Part 2's twenty hand-computed examples are asserted verbatim in
/// HandComputedExampleTests.swift.
final class WasteMathTests: XCTestCase {
    private static func dec(_ s: String) -> Decimal {
        Decimal(string: s)!
    }

    private func price(_ key: String, _ usdPerKg: Decimal) -> PriceFactor {
        PriceFactor(
            ingredientKey: key, usdPerKg: usdPerKg,
            displayQuantity: nil, displayPriceUsd: nil, sourceSeries: nil, citationId: "t1"
        )
    }

    private func emission(_ key: String, _ low: Decimal, _ central: Decimal, _ high: Decimal) -> EmissionFactor {
        EmissionFactor(
            ingredientKey: key, owidEntity: nil,
            kgCo2ePerKg: Range3(low: low, central: central, high: high), citationId: "t2"
        )
    }

    func testDiscardPricesAndEmissionsWithUncertainty() throws {
        // 1000 g beef discarded. $11.00/kg; 59.6 (low 50.0, high 70.0) kg CO2e/kg.
        var ledger = WasteLedger(
            prices: [price("beef", Self.dec("11.0"))],
            emissions: [emission("beef", Self.dec("50.0"), Self.dec("59.6"), Self.dec("70.0"))]
        )
        ledger.record(KitchenEvent(kind: .add, ingredientKey: "beef", grams: Self.dec("1000")))
        ledger.record(KitchenEvent(
            kind: .discard, ingredientKey: "beef", grams: Self.dec("1000"),
            on: "2026-10-10", lotUseBy: "2026-10-05"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.wasted.grams, Self.dec("1000.0"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), Self.dec("11.00"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), Self.dec("59.600"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.low), Self.dec("50.000"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.high), Self.dec("70.000"))
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.notCounted.grams, Self.dec("1000.0"), "add events are corrections, not outcomes")
        XCTAssertNil(result.notCounted.moneyUsd)
    }

    func testConsumeBeforeUseByCountsAsSaved() throws {
        // 450 g rice consumed 2026-10-09 with use-by 2026-10-12: saved.
        // $1.30/kg -> 0.45 kg x 1.30 = 0.585 -> $0.59 at output.
        // 4.0 kg CO2e/kg point estimate -> 1.8.
        var ledger = WasteLedger(
            prices: [price("rice", Self.dec("1.30"))],
            emissions: [emission("rice", Self.dec("4.0"), Self.dec("4.0"), Self.dec("4.0"))]
        )
        ledger.record(KitchenEvent(kind: .add, ingredientKey: "rice", grams: Self.dec("1000")))
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "rice", grams: Self.dec("450"),
            on: "2026-10-09", lotUseBy: "2026-10-12"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.saved.grams, Self.dec("450.0"))
        XCTAssertEqual(try XCTUnwrap(result.saved.moneyUsd), Self.dec("0.59"))
        XCTAssertEqual(try XCTUnwrap(result.saved.kgCo2e?.central), Self.dec("1.800"))
        XCTAssertEqual(result.usedLate.grams, Self.dec("0.0"))
    }

    func testConsumeOnUseByDayStillCountsAsSaved() {
        // Use-by dates are inclusive: same-day consumption is still saved.
        var ledger = WasteLedger(
            prices: [price("milk", Self.dec("0.90"))],
            emissions: [emission("milk", Self.dec("1.4"), Self.dec("1.4"), Self.dec("1.4"))]
        )
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "milk", grams: Self.dec("250"),
            on: "2026-10-12", lotUseBy: "2026-10-12"
        ))

        XCTAssertEqual(ledger.result().saved.grams, Self.dec("250.0"))
    }

    func testConsumeAfterUseByIsUsedLateNeverSaved() throws {
        // Sam's copy rule: food eaten after its use-by is food used late,
        // not food saved.
        var ledger = WasteLedger(
            prices: [price("yogurt", Self.dec("2.0"))],
            emissions: [emission("yogurt", Self.dec("1.3"), Self.dec("1.3"), Self.dec("1.3"))]
        )
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "yogurt", grams: Self.dec("200"),
            on: "2026-10-10", lotUseBy: "2026-10-05"
        ))

        let result = ledger.result()
        XCTAssertEqual(result.usedLate.grams, Self.dec("200.0"))
        XCTAssertEqual(result.saved.grams, Self.dec("0.0"))
        XCTAssertEqual(try XCTUnwrap(result.usedLate.moneyUsd), Self.dec("0.40"))
    }

    func testConsumeWithoutUseByEvidenceIsUnknownNotSaved() {
        var ledger = WasteLedger(
            prices: [price("pasta", Self.dec("1.5"))],
            emissions: [emission("pasta", Self.dec("1.8"), Self.dec("1.8"), Self.dec("1.8"))]
        )
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "pasta", grams: Self.dec("120"), on: "2026-10-10"))
        ledger.record(KitchenEvent(
            kind: .consume, ingredientKey: "pasta", grams: Self.dec("80"),
            lotUseBy: "2026-10-11" // no event date -> cannot compare
        ))

        let result = ledger.result()
        XCTAssertEqual(result.consumedUnknown.grams, Self.dec("200.0"))
        XCTAssertEqual(result.saved.grams, Self.dec("0.0"))
    }

    func testAggregationAcrossIngredientsSumsUnroundedThenRounds() throws {
        // 300 g rice ($2.00/kg, 4.0) + 700 g beans ($3.00/kg, 2.0), both wasted.
        var ledger = WasteLedger(
            prices: [price("rice", Self.dec("2.0")), price("beans", Self.dec("3.0"))],
            emissions: [
                emission("rice", Self.dec("4.0"), Self.dec("4.0"), Self.dec("4.0")),
                emission("beans", Self.dec("2.0"), Self.dec("2.0"), Self.dec("2.0")),
            ]
        )
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "rice", grams: Self.dec("300"), on: "2026-10-10"))
        ledger.record(KitchenEvent(kind: .expire, ingredientKey: "beans", grams: Self.dec("700"), on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(result.wasted.grams, Self.dec("1000.0"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), Self.dec("2.70")) // 0.6 + 2.1
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), Self.dec("2.600")) // 1.2 + 1.4
    }

    func testRoundingBoundaryCase() throws {
        // 123.5 g at $1.25/kg: 0.1235 kg x 1.25 = 0.154375 -> $0.15.
        // 123.5 g at 0.333 kg CO2e/kg: 0.1235 x 0.333 = 0.0411205 -> 0.041.
        var ledger = WasteLedger(
            prices: [price("tofu", Self.dec("1.25"))],
            emissions: [emission("tofu", Self.dec("0.333"), Self.dec("0.333"), Self.dec("0.333"))]
        )
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "tofu", grams: Self.dec("123.5"), on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), Self.dec("0.15"))
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), Self.dec("0.041"))
        XCTAssertEqual(result.wasted.grams, Self.dec("123.5"))
    }

    func testDecimalHalfUpTiesRoundAwayFromZero() throws {
        // model.md §4's binding ties, computed on the decimal representation:
        // 0.25 kg x 9.87 = 2.4675 -> 2.468 (binary floats misround this to 2.467),
        // 6.25 kg x 3.15 = 19.6875 -> 19.688.
        var ledger = WasteLedger(
            prices: [price("sparkling", Self.dec("0.0"))], // priced so money counts; $0/kg is a free ingredient
            emissions: [emission("sparkling", Self.dec("9.87"), Self.dec("9.87"), Self.dec("9.87"))]
        )
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "sparkling", grams: Self.dec("250"), on: "2026-10-10"))

        var ledger2 = WasteLedger(
            prices: [price("milk", Self.dec("3.15"))],
            emissions: [emission("milk", Self.dec("3.15"), Self.dec("3.15"), Self.dec("3.15"))]
        )
        ledger2.record(KitchenEvent(kind: .discard, ingredientKey: "milk", grams: Self.dec("6250"), on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), Self.dec("2.468"), "0.25 x 9.87 must round half-up to 2.468")

        let result2 = ledger2.result()
        XCTAssertEqual(try XCTUnwrap(result2.wasted.moneyUsd), Self.dec("19.69"), "6.25 x 3.15 = 19.6875 -> 19.69 at 2dp")
        XCTAssertEqual(try XCTUnwrap(result2.wasted.kgCo2e?.central), Self.dec("19.688"))
    }

    func testDroppedEventCounterForNonPositiveGrams() {
        var ledger = WasteLedger()
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "rice", grams: Self.dec("0")))
        ledger.record(KitchenEvent(kind: .consume, ingredientKey: "rice", grams: Self.dec("-5")))
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "rice", grams: Self.dec("100"), on: "2026-10-10"))
        XCTAssertEqual(ledger.droppedEventCount, 2)
        XCTAssertEqual(ledger.result().wasted.grams, Self.dec("100.0"))
    }

    func testEmptyLedgerProducesZeroResult() {
        let result = WasteLedger().result()
        XCTAssertEqual(result.saved.grams, Self.dec("0.0"))
        XCTAssertEqual(result.wasted.grams, Self.dec("0.0"))
        XCTAssertNil(result.saved.moneyUsd)
        XCTAssertNil(result.saved.kgCo2e)
        XCTAssertTrue(result.refusals.isEmpty)
    }
}
