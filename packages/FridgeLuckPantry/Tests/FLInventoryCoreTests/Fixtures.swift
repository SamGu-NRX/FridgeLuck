import XCTest
import FLDomain
import FLPersistence
@testable import FLInventoryCore

/// Shared synthetic fixtures for the pantry ledger tests. Everything here is
/// deterministic: fixed instants, valid-by-construction builders (a malformed
/// fixture fails loudly at the builder, not silently mid-test).
enum Fixtures {
    static let household = try! FLHouseholdID("hh-test-1")
    static let household2 = try! FLHouseholdID("hh-test-2")
    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    static func grams(_ value: Double) -> QuantityEvidence {
        .sourceGrams(try! GramMass(grams: value))
    }

    static func ingredient(
        _ name: String,
        fdc: Int? = nil,
        local: Int64? = nil
    ) -> IngredientReference {
        try! IngredientReference(
            fdc: fdc.map { try! FDCIngredientKey(fdcID: $0) },
            localIngredientID: local,
            canonicalName: name
        )
    }

    static func purchase(
        _ id: String,
        ingredient: IngredientReference,
        grams value: Double?,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        preparation: String? = nil,
        source: FLStockEventSource = .receipt,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .purchase,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            preparation: preparation,
            source: source,
            timestamp: at
        )
    }

    static func leftoverPurchase(
        _ id: String,
        ingredient: IngredientReference,
        grams value: Double?,
        cookID: String,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        preparation: String? = nil,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .purchase,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            cookID: cookID,
            preparation: preparation,
            source: .leftover,
            timestamp: at
        )
    }

    static func consumption(
        _ id: String,
        ingredient: IngredientReference,
        grams value: Double?,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        lotID: String? = nil,
        cookID: String? = nil,
        source: FLStockEventSource = .manual,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .consumption,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            lotID: lotID,
            cookID: cookID,
            source: source,
            timestamp: at
        )
    }

    static func spoilage(
        _ id: String,
        ingredient: IngredientReference,
        grams value: Double?,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        lotID: String? = nil,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .spoilage,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            lotID: lotID,
            source: .manual,
            timestamp: at
        )
    }

    static func scan(
        _ id: String,
        ingredient: IngredientReference,
        grams value: Double?,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .observation,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            source: .scan,
            timestamp: at
        )
    }

    static func correction(
        _ id: String,
        priorEventID: String,
        mode: FLStockCorrection.Mode,
        ingredient: IngredientReference,
        grams value: Double?,
        command: String = "cmd-1",
        household: FLHouseholdID = Fixtures.household,
        at: Date = t0
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: command,
            householdID: household,
            kind: .correction,
            ingredient: ingredient,
            quantity: value.map { grams($0) } ?? .unknown,
            source: .manual,
            timestamp: at,
            supersedes: FLStockCorrection(
                priorEventID: try! StockEventID(priorEventID),
                mode: mode
            )
        )
    }

    /// A fresh in-memory ledger, migrated like the app would (central
    /// registry first, then the pantry's own namespaced migrations).
    static func ledger(allowedHousehold: FLHouseholdID? = nil) throws -> FLPantryLedger {
        let appDB = try AppDatabase.inMemory()
        try appDB.migrate()
        return try FLPantryLedger(db: appDB, allowedHouseholdID: allowedHousehold)
    }

    /// Assert a block throws exactly `expected` (FLInventoryError is Equatable).
    static func expectRefusal(
        _ expected: FLInventoryError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () throws -> Void
    ) {
        do {
            try block()
            XCTFail("expected the ledger to refuse with \(expected)", file: file, line: line)
        } catch let error as FLInventoryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
