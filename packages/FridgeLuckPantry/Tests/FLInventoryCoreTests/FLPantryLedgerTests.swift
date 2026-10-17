import XCTest
import FLDomain
import FLPersistence
@testable import FLInventoryCore

/// The ledger contract: append-only events, idempotent retries, atomic
/// commands, household scoping, and snapshots that fold the same way the
/// pure fold does — because they ARE the same fold.
final class FLPantryLedgerTests: XCTestCase {
    let milk = Fixtures.ingredient("whole milk", fdc: 746778)
    let eggs = Fixtures.ingredient("eggs", fdc: 748264)

    func testApplyPurchaseAndSnapshotRoundTrip() throws {
        let ledger = try Fixtures.ledger()
        let outcome = try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 500))
        XCTAssertEqual(outcome, .applied)

        let snapshot = try ledger.snapshot(householdID: Fixtures.household)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].lotID, "e1")
        XCTAssertEqual(snapshot[0].remaining.gramsIfKnown?.grams, 500)
        XCTAssertEqual(snapshot[0].lastConfirmedAt, Fixtures.t0)
        XCTAssertEqual(snapshot[0].lastConfirmedSource, .receipt)

        let item = try ledger.itemStock(householdID: Fixtures.household, ingredient: milk)
        XCTAssertEqual(item?.totalKnownRemainingGrams, 500)
        XCTAssertEqual(item?.groupKey, "fdc:746778")
    }

    func testIdempotentRetryNeverDoublesStock() throws {
        let ledger = try Fixtures.ledger()
        let event = Fixtures.purchase("e1", ingredient: milk, grams: 500)
        XCTAssertEqual(try ledger.apply(event), .applied)
        // The confirmation retry re-sends the SAME event with the SAME
        // command ID — the ledger answers "already applied".
        XCTAssertEqual(try ledger.apply(event), .alreadyApplied)
        XCTAssertEqual(try ledger.snapshot(householdID: Fixtures.household)[0].remaining.gramsIfKnown?.grams, 500)
        XCTAssertTrue(try ledger.hasCommand(householdID: Fixtures.household, commandID: "cmd-1"))

        // A different command reusing the event ID is refused, not applied.
        let impostor = Fixtures.purchase("e1", ingredient: milk, grams: 100, command: "cmd-OTHER")
        Fixtures.expectRefusal(.duplicateEventID(eventID: "e1")) {
            try ledger.apply(impostor)
        }
        XCTAssertEqual(try ledger.snapshot(householdID: Fixtures.household)[0].remaining.gramsIfKnown?.grams, 500)
    }

    func testRejectedEventMutatesNothing() throws {
        let ledger = try Fixtures.ledger()
        try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 100))

        Fixtures.expectRefusal(.insufficientStock(
            ingredient: "whole milk", availableGrams: 100, requestedGrams: 150, eventID: "e2"
        )) {
            try ledger.apply(Fixtures.consumption("e2", ingredient: milk, grams: 150, command: "c2"))
        }
        XCTAssertEqual(try ledger.events(householdID: Fixtures.household).count, 1, "the refused event is not on the ledger")
        XCTAssertEqual(try ledger.snapshot(householdID: Fixtures.household)[0].remaining.gramsIfKnown?.grams, 100)
        XCTAssertFalse(try ledger.hasCommand(householdID: Fixtures.household, commandID: "c2"))
    }

    func testBatchCommandIsAllOrNothing() throws {
        let ledger = try Fixtures.ledger()
        // One command: a good purchase and an impossible draw-down. Either
        // both land or neither does.
        let batch = [
            Fixtures.purchase("e1", ingredient: milk, grams: 100, command: "cmd-mixed"),
            Fixtures.consumption("e2", ingredient: milk, grams: 500, command: "cmd-mixed"),
        ]
        Fixtures.expectRefusal(.insufficientStock(
            ingredient: "whole milk", availableGrams: 100, requestedGrams: 500, eventID: "e2"
        )) {
            try ledger.applyBatch(batch)
        }
        XCTAssertEqual(try ledger.events(householdID: Fixtures.household).count, 0, "no partial write")
        XCTAssertFalse(try ledger.hasCommand(householdID: Fixtures.household, commandID: "cmd-mixed"))
    }

    func testCookConsumptionLandsAsOneCommand() throws {
        let ledger = try Fixtures.ledger()
        try ledger.applyBatch([
            Fixtures.purchase("p1", ingredient: milk, grams: 500, command: "c0"),
            Fixtures.purchase("p2", ingredient: eggs, grams: 300, command: "c0"),
        ])
        // A cook consumed three things (milk twice on two lines, eggs once):
        // one command, three events, all applied together.
        let cookBatch = [
            Fixtures.consumption("k1", ingredient: milk, grams: 200, command: "cook-7", cookID: "cook-7", source: .cook),
            Fixtures.consumption("k2", ingredient: milk, grams: 50, command: "cook-7", cookID: "cook-7", source: .cook),
            Fixtures.consumption("k3", ingredient: eggs, grams: 120, command: "cook-7", cookID: "cook-7", source: .cook),
        ]
        XCTAssertEqual(try ledger.applyBatch(cookBatch), .applied)
        XCTAssertEqual(try ledger.itemStock(householdID: Fixtures.household, ingredient: milk)?.totalKnownRemainingGrams, 250)
        XCTAssertEqual(try ledger.itemStock(householdID: Fixtures.household, ingredient: eggs)?.totalKnownRemainingGrams, 180)

        // Retrying the whole cook command changes nothing.
        XCTAssertEqual(try ledger.applyBatch(cookBatch), .alreadyApplied)
        XCTAssertEqual(try ledger.itemStock(householdID: Fixtures.household, ingredient: milk)?.totalKnownRemainingGrams, 250)
    }

    func testCorrectionsFlowThroughTheLedger() throws {
        let ledger = try Fixtures.ledger()
        try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 500))
        try ledger.apply(Fixtures.correction("e2", priorEventID: "e1", mode: .corrects, ingredient: milk, grams: 300, command: "c2"))

        let snapshot = try ledger.snapshot(householdID: Fixtures.household)
        XCTAssertEqual(snapshot[0].remaining.gramsIfKnown?.grams, 300)
        // Corrections supersede, they never erase: both events remain.
        XCTAssertEqual(try ledger.events(householdID: Fixtures.household).count, 2)
    }

    func testHouseholdsAreScoped() throws {
        let ledger = try Fixtures.ledger()
        try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 500, household: Fixtures.household))
        try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 700, command: "c2", household: Fixtures.household2))

        XCTAssertEqual(try ledger.snapshot(householdID: Fixtures.household)[0].remaining.gramsIfKnown?.grams, 500)
        XCTAssertEqual(try ledger.snapshot(householdID: Fixtures.household2)[0].remaining.gramsIfKnown?.grams, 700)

        // A scoped ledger (first release: one household per phone) refuses
        // events for any other household instead of mixing them in.
        let scoped = try Fixtures.ledger(allowedHousehold: Fixtures.household)
        Fixtures.expectRefusal(.householdMismatch(eventID: "e9")) {
            try scoped.apply(Fixtures.purchase("e9", ingredient: milk, grams: 1, command: "c9", household: Fixtures.household2))
        }
        XCTAssertEqual(try scoped.events(householdID: Fixtures.household2).count, 0)
    }

    func testOnDiskLedgerSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fl-pantry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("pantry.sqlite")
        let first = try AppDatabase.open(at: url)
        try first.migrate()
        let ledger1 = try FLPantryLedger(db: first)
        try ledger1.apply(Fixtures.purchase("e1", ingredient: milk, grams: 500))
        try ledger1.apply(Fixtures.consumption("e2", ingredient: milk, grams: 120, command: "c2"))

        // Reopen: a brand-new ledger over the same file sees the same truth.
        let reopened = try AppDatabase.open(at: url)
        let ledger2 = try FLPantryLedger(db: reopened)
        let snapshot = try ledger2.snapshot(householdID: Fixtures.household)
        XCTAssertEqual(snapshot[0].remaining.gramsIfKnown?.grams, 380)
        XCTAssertEqual(try ledger2.events(householdID: Fixtures.household).count, 2)
        XCTAssertEqual(try ledger2.hasCommand(householdID: Fixtures.household, commandID: "c2"), true)
    }

    func testUnmeasuredConsumptionThroughTheLedger() throws {
        let ledger = try Fixtures.ledger()
        try ledger.apply(Fixtures.purchase("e1", ingredient: milk, grams: 500))
        try ledger.apply(Fixtures.consumption("e2", ingredient: milk, grams: nil, command: "c2"))
        let lot = try ledger.snapshot(householdID: Fixtures.household)[0]
        XCTAssertTrue(lot.remaining.isUnknown, "the ledger never turns an unmeasured removal into a number")
        XCTAssertNil(try ledger.itemStock(householdID: Fixtures.household, ingredient: milk)?.totalKnownRemainingGrams)
    }
}
