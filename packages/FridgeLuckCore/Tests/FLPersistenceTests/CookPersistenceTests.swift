import XCTest
import FLDomain
@testable import FLPersistence

/// Review round 2, item 1: the Cook + PreferenceEvent persistence pair.
/// SPEC (project overview): "Cook and preference-event records are designed
/// to persist as an atomic pair." These tests pin three behaviors:
///
/// 1. the migration creates both tables,
/// 2. the paired write persists both records and reads them back equal,
/// 3. a failure between the two inserts persists NEITHER — no half-pairs on
///    any failure path.
///
/// Red-first: against the pre-fix code the migration test failed at runtime
/// (no such tables) and the paired-write tests failed to compile (no such
/// API) — both outputs are recorded in the PR Proof section.
final class CookPersistenceTests: XCTestCase {
    // MARK: Fixtures (synthetic data only)

    private func makeCook(id: String = "cook-1") throws -> Cook {
        try Cook(
            id: id,
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 2),
            servings: 2,
            substitutions: [
                try CookSubstitution(
                    from: IngredientReference(canonicalName: "onion"),
                    to: IngredientReference(canonicalName: "shallot"),
                    necessity: .necessary
                )
            ],
            rating: 4,
            note: "extra crispy",
            startedAt: try FLTimestamp.decode("2026-10-11T18:02:03.500Z", target: "test"),
            completedAt: try FLTimestamp.decode("2026-10-11T18:44:56.250Z", target: "test")
        )
    }

    private func makeEvent(for cook: Cook, id: String = "event-1") throws -> PreferenceEvent {
        try PreferenceEvent(
            id: id,
            kind: .cookCompleted,
            timestamp: cook.completedAt,
            recipeRevision: cook.recipeRevision,
            source: .appObserved,
            rating: cook.rating,
            wouldRepeat: true,
            note: cook.note
        )
    }

    private func countRows(in table: String, of db: AppDatabase) throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    // MARK: 1. Migration

    func testMigrateCreatesCookAndPreferenceEventTables() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        XCTAssertTrue(try db.tableExists("fl_cooks"), "the cook table must exist after migrations")
        XCTAssertTrue(try db.tableExists("fl_preference_events"), "the preference-event table must exist after migrations")
        XCTAssertEqual(
            try db.appliedMigrations(),
            ["v1-baseline", "v2-cooks-preference-events"],
            "the pair's tables are one additive migration, appended after the baseline"
        )
    }

    func testOnDiskMigrationAppliesOnceAndTablesSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CookPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.sqlite3")
        let db = try AppDatabase.open(at: url)
        try db.migrate()
        XCTAssertTrue(try db.tableExists("fl_cooks"))
        XCTAssertTrue(try db.tableExists("fl_preference_events"))

        let reopened = try AppDatabase.open(at: url)
        try reopened.migrate()
        XCTAssertEqual(try reopened.appliedMigrations(), ["v1-baseline", "v2-cooks-preference-events"])
    }

    // MARK: 2. The paired write

    func testPairedWritePersistsBothRecordsAndReadsBackEqual() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let cook = try makeCook()
        let event = try makeEvent(for: cook)

        try db.writeCompletedCook(cook, preferenceEvent: event)

        let readCook = try XCTUnwrap(try db.completedCook(id: cook.id), "the cook must read back")
        XCTAssertEqual(readCook, cook, "the persisted cook must round-trip exactly")
        let readEvent = try XCTUnwrap(try db.preferenceEvent(id: event.id.rawValue), "the event must read back")
        XCTAssertEqual(readEvent, event, "the persisted event must round-trip exactly")
    }

    func testPairedWriteRoundTripsAMinimalCookAndEvent() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let cook = try Cook(
            id: "cook-min",
            recipeRevision: RecipeKey(source: .catalog, sourceRecipeID: "soup", revision: 7),
            servings: 1,
            rating: 5,
            completedAt: try FLTimestamp.decode("2026-10-12T07:00:00Z", target: "test")
        )
        let event = try PreferenceEvent(
            id: "event-min",
            kind: .exposed,
            timestamp: try FLTimestamp.decode("2026-10-12T06:59:00Z", target: "test"),
            recipeRevision: cook.recipeRevision,
            source: .userExplicit
        )

        try db.writeCompletedCook(cook, preferenceEvent: event)

        XCTAssertEqual(try db.completedCook(id: cook.id), cook)
        XCTAssertEqual(try db.preferenceEvent(id: event.id.rawValue), event)
    }

    func testReadersReturnNilForUnknownIDs() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        XCTAssertNil(try db.completedCook(id: "nope"))
        XCTAssertNil(try db.preferenceEvent(id: "nope"))
    }

    // MARK: 3. Rollback — no half-pairs on any failure path

    /// The seam-based red test: an injected failure between the two inserts
    /// must roll back BOTH writes. Run against the real transaction.
    func testInjectedFailureBetweenTheTwoWritesPersistsNeither() throws {
        struct InjectedFailure: Error {}
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let cook = try makeCook()
        let event = try makeEvent(for: cook)

        XCTAssertThrowsError(
            try db.writeCompletedCook(cook, preferenceEvent: event, betweenWrites: { _ in
                throw InjectedFailure()
            }),
            "the injected failure must surface, not be swallowed"
        )

        XCTAssertNil(try db.completedCook(id: cook.id), "no half-pairs: the first write must roll back")
        XCTAssertNil(try db.preferenceEvent(id: event.id.rawValue), "no half-pairs: nothing of the pair may persist")
        XCTAssertEqual(try countRows(in: "fl_cooks", of: db), 0)
        XCTAssertEqual(try countRows(in: "fl_preference_events", of: db), 0)
    }

    /// The same transaction with a NON-throwing seam writes both rows — the
    /// injection seam itself must not be what suppresses the second write.
    func testNonThrowingInjectionBetweenTheTwoWritesPersistsBoth() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let cook = try makeCook()
        let event = try makeEvent(for: cook)

        try db.writeCompletedCook(cook, preferenceEvent: event, betweenWrites: { _ in })

        XCTAssertEqual(try countRows(in: "fl_cooks", of: db), 1)
        XCTAssertEqual(try countRows(in: "fl_preference_events", of: db), 1)
    }

    /// A natural failure without the seam: the second insert hits the event
    /// table's primary key, the whole transaction — the first insert included —
    /// must roll back.
    func testDuplicateEventIDFailsTheWholePairWithoutLeavingTheFirstCook() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let firstCook = try makeCook(id: "cook-1")
        let sharedEvent = try makeEvent(for: firstCook, id: "shared-event")
        try db.writeCompletedCook(firstCook, preferenceEvent: sharedEvent)

        let secondCook = try makeCook(id: "cook-2")
        XCTAssertThrowsError(
            try db.writeCompletedCook(secondCook, preferenceEvent: sharedEvent),
            "reusing the event's primary key must fail the second write"
        )

        XCTAssertNil(try db.completedCook(id: "cook-2"), "no half-pairs: the second cook must roll back with its failed pair")
        XCTAssertEqual(try countRows(in: "fl_cooks", of: db), 1, "only the first, complete pair remains")
        XCTAssertEqual(try countRows(in: "fl_preference_events", of: db), 1)
    }

    /// The first insert can also fail (duplicate cook id): neither row of the
    /// new pair may persist.
    func testDuplicateCookIDFailsTheWholePairWithoutLeavingTheEvent() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        let firstCook = try makeCook(id: "cook-1")
        try db.writeCompletedCook(firstCook, preferenceEvent: try makeEvent(for: firstCook, id: "event-1"))

        let secondEvent = try makeEvent(for: firstCook, id: "event-2")
        XCTAssertThrowsError(
            try db.writeCompletedCook(firstCook, preferenceEvent: secondEvent),
            "reusing the cook's primary key must fail the write"
        )

        XCTAssertNil(try db.preferenceEvent(id: "event-2"), "no half-pairs: the event must roll back with its failed cook")
        XCTAssertEqual(try countRows(in: "fl_preference_events", of: db), 1)
        XCTAssertEqual(try countRows(in: "fl_cooks", of: db), 1)
    }
}
