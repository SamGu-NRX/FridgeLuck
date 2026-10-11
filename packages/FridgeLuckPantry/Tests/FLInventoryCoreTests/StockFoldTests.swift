import XCTest
import FLDomain
@testable import FLInventoryCore

/// The fold invariants (SPEC 3.2): corrections supersede rather than erase,
/// scans observe while purchases add, stock never goes negative, unknown
/// evidence stays unknown, and identity grouping never guesses.
final class StockFoldTests: XCTestCase {
    let milk = Fixtures.ingredient("whole milk", fdc: 746778)

    // MARK: Consumption and FIFO draw-down

    func testConsumptionDrawsDownOldestLotFirst() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500, command: "c1", at: Fixtures.t0),
            Fixtures.purchase("e2", ingredient: milk, grams: 300, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
            Fixtures.consumption("e3", ingredient: milk, grams: 600, command: "c3", at: Fixtures.t0.addingTimeInterval(120)),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock.count, 1)
        XCTAssertEqual(stock[0].lots.count, 2)
        XCTAssertEqual(stock[0].lots[0].lotID, "e1")
        XCTAssertEqual(stock[0].lots[0].remaining.gramsIfKnown?.grams, 0, "the oldest lot is emptied first")
        XCTAssertEqual(stock[0].lots[1].remaining.gramsIfKnown?.grams, 200)
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 200)
    }

    func testTargetedConsumptionDrawsFromTheNamedLot() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.purchase("e2", ingredient: milk, grams: 300, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
            Fixtures.consumption("e3", ingredient: milk, grams: 100, lotID: "e2", command: "c3", at: Fixtures.t0.addingTimeInterval(120)),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].lots[0].remaining.gramsIfKnown?.grams, 500, "the untargeted lot is untouched")
        XCTAssertEqual(stock[0].lots[1].remaining.gramsIfKnown?.grams, 200)
    }

    // MARK: Corrections supersede, never erase

    func testCorrectionReplacesTheQuantityButKeepsHistory() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.correction("e2", priorEventID: "e1", mode: .corrects, ingredient: milk, grams: 300, command: "c2"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 300, "the correcting quantity wins")
        // The lot keeps the ORIGINAL event's identity; only the amount changed.
        XCTAssertEqual(stock[0].lots[0].lotID, "e1")
    }

    func testRetractionRemovesTheEventAndItsStock() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.purchase("e2", ingredient: milk, grams: 100, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
            Fixtures.correction("e3", priorEventID: "e1", mode: .retracts, ingredient: milk, grams: nil, command: "c3"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].lots.count, 1, "the retracted purchase's lot is gone")
        XCTAssertEqual(stock[0].lots[0].lotID, "e2")
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 100)
    }

    func testCorrectionAfterRetractionRevivesTheRootWithTheNewQuantity() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.correction("e2", priorEventID: "e1", mode: .retracts, ingredient: milk, grams: nil, command: "c2"),
            Fixtures.correction("e3", priorEventID: "e1", mode: .corrects, ingredient: milk, grams: 250, command: "c3"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 250, "the last correction of a root decides")
    }

    // MARK: Scans observe, purchases add

    func testScanObservationReconcilesInsteadOfStacking() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.scan("e2", ingredient: milk, grams: 200, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 200, "the scan saw the shelf: total is what was seen, not 700")
        XCTAssertEqual(stock[0].lots.count, 1)
        XCTAssertEqual(stock[0].lastConfirmedAt, Fixtures.t0.addingTimeInterval(60))
        XCTAssertEqual(stock[0].lastConfirmedSource, .scan)
    }

    func testAmountlessScanConfirmsPresenceWithoutInventingAQuantity() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.scan("e2", ingredient: milk, grams: nil, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 500, "an amountless scan never zeroes or rewrites known stock")
        XCTAssertEqual(stock[0].lots[0].lastConfirmedAt, Fixtures.t0.addingTimeInterval(60), "presence evidence refreshed")
        XCTAssertEqual(stock[0].lots[0].lastConfirmedSource, .scan)
    }

    // MARK: Unknown evidence stays unknown

    func testUnmeasuredConsumptionLeavesTheAmountUnknown() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.consumption("e2", ingredient: milk, grams: nil, command: "c2", at: Fixtures.t0.addingTimeInterval(60)),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].lots[0].remaining.isUnknown, true, "how much is left is unknown — never zero, never 500")
        XCTAssertNil(stock[0].totalKnownRemainingGrams)
    }

    func testLeftoverPurchaseIsALot() throws {
        let events = [
            Fixtures.leftoverPurchase("e1", ingredient: milk, grams: 350, cookID: "cook-7", preparation: "cooked"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].lots.count, 1)
        XCTAssertEqual(stock[0].lots[0].remaining.gramsIfKnown?.grams, 350)
        XCTAssertEqual(stock[0].lots[0].preparation, "cooked", "leftovers carry their preparation form")
        XCTAssertEqual(stock[0].lastConfirmedSource, .leftover)
    }

    // MARK: Stock never goes negative

    func testOverdrawIsRefused() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 100),
            Fixtures.consumption("e2", ingredient: milk, grams: 150, command: "c2"),
        ]
        Fixtures.expectRefusal(.insufficientStock(
            ingredient: "whole milk", availableGrams: 100, requestedGrams: 150, eventID: "e2"
        )) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testTargetedOverdrawIsRefused() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.purchase("e2", ingredient: milk, grams: 100, command: "c2"),
            Fixtures.consumption("e3", ingredient: milk, grams: 150, lotID: "e2", command: "c3"),
        ]
        Fixtures.expectRefusal(.insufficientStock(
            ingredient: "whole milk", availableGrams: 100, requestedGrams: 150, eventID: "e3"
        )) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testConsumptionWithNoStockAtAllIsRefused() throws {
        let events = [Fixtures.consumption("e1", ingredient: milk, grams: 50)]
        Fixtures.expectRefusal(.insufficientStock(
            ingredient: "whole milk", availableGrams: 0, requestedGrams: 50, eventID: "e1"
        )) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testDrawFromAnUncountedLotStaysUncounted() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: nil),
            Fixtures.consumption("e2", ingredient: milk, grams: 100, command: "c2"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock[0].lots[0].remaining.isUnknown, true, "drawing from an uncounted lot cannot invent a remainder")
    }

    // MARK: Identity grouping

    func testGroupKeyPrefersTheStrongestIdentity() throws {
        let byFDC = Fixtures.ingredient("whole milk", fdc: 746778, local: 12)
        let byLocal = Fixtures.ingredient("whole milk", local: 12)
        let byName = Fixtures.ingredient("Whole Milk")
        XCTAssertEqual(FLStockFold.groupKey(for: byFDC), "fdc:746778")
        XCTAssertEqual(FLStockFold.groupKey(for: byLocal), "local:12")
        XCTAssertEqual(FLStockFold.groupKey(for: byName), "name:whole milk", "name grouping is case-insensitive")
        XCTAssertNotEqual(FLStockFold.groupKey(for: byFDC), FLStockFold.groupKey(for: byLocal),
                          "FDC and local identity are deliberately distinct groups")
    }

    func testNameGroupingIsCaseInsensitive() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: Fixtures.ingredient("Whole Milk"), grams: 500),
            Fixtures.consumption("e2", ingredient: Fixtures.ingredient("whole milk"), grams: 100, command: "c2"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock.count, 1, "the same shelf recorded with different case is one item")
        XCTAssertEqual(stock[0].totalKnownRemainingGrams, 400)
    }

    // MARK: Households never mix

    func testHouseholdsFoldIndependently() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500, household: Fixtures.household),
            Fixtures.purchase("e1", ingredient: milk, grams: 700, household: Fixtures.household2, command: "c2"),
        ]
        let stock = try FLStockFold.fold(events: events)
        XCTAssertEqual(stock.count, 2, "the same event ID in two households is two independent facts")
        let byHouseholdStock = stock.map(\.totalKnownRemainingGrams)
        XCTAssertEqual(Set(byHouseholdStock.compactMap { $0 }), Set([500.0, 700.0]))
    }

    // MARK: Impossible histories are refused

    func testDuplicateEventIDIsRefused() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.purchase("e1", ingredient: milk, grams: 100, command: "c2"),
        ]
        Fixtures.expectRefusal(.duplicateEventID(eventID: "e1")) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testCorrectionReferencingAnUnknownEventIsRefused() throws {
        let events = [
            Fixtures.correction("e9", priorEventID: "missing", mode: .retracts, ingredient: milk, grams: nil),
        ]
        Fixtures.expectRefusal(.unknownEventReference(eventID: "e9", referencedEventID: "missing")) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testCorrectionCannotMoveTheIngredient() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.correction("e2", priorEventID: "e1", mode: .corrects, ingredient: Fixtures.ingredient("skim milk", fdc: 746778), grams: 300, command: "c2"),
        ]
        Fixtures.expectRefusal(.correctionIngredientMismatch(
            eventID: "e2", correctedIngredient: "skim milk", recordedIngredient: "whole milk"
        )) {
            _ = try FLStockFold.fold(events: events)
        }
    }

    func testCorrectionTargetingAnotherCorrectionIsRefused() throws {
        let events = [
            Fixtures.purchase("e1", ingredient: milk, grams: 500),
            Fixtures.correction("e2", priorEventID: "e1", mode: .corrects, ingredient: milk, grams: 300, command: "c2"),
            Fixtures.correction("e3", priorEventID: "e2", mode: .corrects, ingredient: milk, grams: 100, command: "c3"),
        ]
        Fixtures.expectRefusal(.invalidEvent(
            eventID: "e3",
            reason: "corrections target the event they revise, not another correction"
        )) {
            _ = try FLStockFold.fold(events: events)
        }
    }
}
