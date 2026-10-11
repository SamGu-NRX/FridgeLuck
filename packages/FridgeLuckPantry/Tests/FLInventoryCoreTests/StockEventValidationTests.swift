import XCTest
import FLDomain
@testable import FLInventoryCore

/// The event construction contract: every rejection rule of the pantry
/// boundary (SPEC 3.2), each pinned by its own test.
final class StockEventValidationTests: XCTestCase {
    let milk = Fixtures.ingredient("whole milk", fdc: 746778)

    func testPurchaseCannotComeFromAScanOrACook() throws {
        for source in [FLStockEventSource.scan, .cook] {
            XCTAssertThrowsError(try FLStockEvent(
                id: "e1", commandID: "cmd", householdID: Fixtures.household,
                kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
                source: source, timestamp: Fixtures.t0
            )) { error in
                guard case FLDomainError.validation(let target, _) = error else {
                    return XCTFail("expected a validation error, got \(error)")
                }
                XCTAssertEqual(target, "FLStockEvent.source")
            }
        }
    }

    func testObservationOnlyComesFromAScan() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .observation, ingredient: milk, quantity: .unknown,
            source: .receipt, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.source")
        }
    }

    func testConsumptionComesFromACookRecordOrAManualEntry() throws {
        // A receipt or scan cannot cause consumption.
        for source in [FLStockEventSource.receipt, .scan, .leftover] {
            XCTAssertThrowsError(try FLStockEvent(
                id: "e1", commandID: "cmd", householdID: Fixtures.household,
                kind: .consumption, ingredient: milk, quantity: Fixtures.grams(50),
                source: source, timestamp: Fixtures.t0
            )) { error in
                guard case FLDomainError.validation(let target, _) = error else {
                    return XCTFail("expected a validation error, got \(error)")
                }
                XCTAssertEqual(target, "FLStockEvent.source")
            }
        }
        // Cook-sourced consumption must name the cook.
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .consumption, ingredient: milk, quantity: Fixtures.grams(50),
            source: .cook, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.cookID")
        }
        // Manual consumption must NOT name a cook.
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .consumption, ingredient: milk, quantity: Fixtures.grams(50),
            cookID: "cook-9", source: .manual, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.cookID")
        }
    }

    func testSpoilageIsManualOnly() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .spoilage, ingredient: milk, quantity: Fixtures.grams(50),
            source: .scan, timestamp: Fixtures.t0
        ))
        // And it never names a cook.
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .spoilage, ingredient: milk, quantity: Fixtures.grams(50),
            cookID: "cook-9", source: .manual, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.cookID")
        }
    }

    func testCorrectionsMustNameTheEventTheyRevise() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e2", commandID: "cmd", householdID: Fixtures.household,
            kind: .correction, ingredient: milk, quantity: Fixtures.grams(300),
            source: .manual, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.supersedes")
        }
    }

    func testOnlyCorrectionsSupersede() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
            source: .receipt, timestamp: Fixtures.t0,
            supersedes: FLStockCorrection(priorEventID: try! StockEventID("e0"), mode: .corrects)
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.supersedes")
        }
    }

    func testRetractionCarriesNoQuantity() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e2", commandID: "cmd", householdID: Fixtures.household,
            kind: .correction, ingredient: milk, quantity: Fixtures.grams(1),
            source: .manual, timestamp: Fixtures.t0,
            supersedes: FLStockCorrection(priorEventID: try! StockEventID("e1"), mode: .retracts)
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.quantity")
        }
    }

    func testPurchasesMintLotsAndCannotTargetOne() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
            lotID: "lot-0", source: .receipt, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.lotID")
        }
    }

    func testObservationsReconcileTheItemNotOneLot() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .observation, ingredient: milk, quantity: Fixtures.grams(200),
            lotID: "lot-0", source: .scan, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.lotID")
        }
    }

    func testLeftoverPurchasesNameTheCookTheyCameFrom() throws {
        // Leftover purchase without a cook is refused.
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(200),
            source: .leftover, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.cookID")
        }
        // And a plain purchase must NOT name a cook.
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "cmd", householdID: Fixtures.household,
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
            cookID: "cook-9", source: .receipt, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.cookID")
        }
    }

    func testCommandIDIsRequired() throws {
        XCTAssertThrowsError(try FLStockEvent(
            id: "e1", commandID: "   ", householdID: Fixtures.household,
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
            source: .receipt, timestamp: Fixtures.t0
        )) { error in
            guard case FLDomainError.validation(let target, _) = error else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(target, "FLStockEvent.commandID")
        }
    }

    func testHouseholdAndEventIDAreValidated() throws {
        XCTAssertThrowsError(try FLHouseholdID("   "))
        XCTAssertThrowsError(try StockEventID(""))
        XCTAssertNoThrow(try FLStockEvent(
            id: "e1", commandID: "cmd",
            householdID: try! FLHouseholdID("  hh-x  "),
            kind: .purchase, ingredient: milk, quantity: Fixtures.grams(500),
            source: .receipt, timestamp: Fixtures.t0
        ))
    }

    func testUnknownQuantityIsFirstClassOnAnyKind() throws {
        // A receipt without a weight records unknown and is valid.
        let event = Fixtures.purchase("e1", ingredient: milk, grams: nil)
        XCTAssertTrue(event.quantity.isUnknown)
        XCTAssertNil(event.quantity.gramsIfKnown)
    }

    func testCanonicalJSONRoundTripPreservesEverything() throws {
        let event = Fixtures.correction(
            "e2", priorEventID: "e1", mode: .corrects,
            ingredient: milk, grams: 300, command: "cmd-2"
        )
        let data = try FLJSON.canonicalData(event)
        let decoded = try FLJSON.canonicalDecoder().decode(FLStockEvent.self, from: data)
        XCTAssertEqual(decoded, event)

        // The wire shape keeps provenance next to quantity, per the contract.
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"kind\":\"correction\""), "canonical wire shape changed: \(raw)")
        XCTAssertTrue(raw.contains("\"source\":\"manual\""), "canonical wire shape changed: \(raw)")
        XCTAssertTrue(raw.contains("\"supersedes\":{\"priorEventID\":\"e1\",\"mode\":\"corrects\"}"), "canonical wire shape changed: \(raw)")
    }
}
