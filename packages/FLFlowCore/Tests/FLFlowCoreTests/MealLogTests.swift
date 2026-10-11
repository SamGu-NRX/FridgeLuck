import XCTest
import Foundation
import FLDomain
import FLPersistence
@testable import FLFlowCore

// MARK: - Meal-log hand-off
// The atomic commitment of a finished session: the Cook record and the
// cookCompleted PreferenceEvent are written together or not at all, and the
// stored payloads decode back through the validated initializers.

final class MealLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    private func makeFinishedSession() throws -> CookSession {
        let revision = TestBuilders.revision(
            "galette",
            lines: [TestBuilders.line("l1", "flour", TestBuilders.grams(250))],
            steps: [TestBuilders.step("s1"), TestBuilders.step("s2")]
        )
        let started = try CookSession.start(sessionID: "sess-1", revision: revision, now: t0)
        let afterFirst = try started.completeStep(now: t0.addingTimeInterval(600))
        return try afterFirst.completeStep(now: t0.addingTimeInterval(1200))
    }

    private func makeHandoff(
        session: CookSession,
        cookID: String = "cook-1",
        eventID: String = "evt-1",
        note: String? = "worth repeating"
    ) throws -> MealLog.Handoff {
        try MealLog.makeHandoff(
            session: session,
            cookID: cookID,
            eventID: eventID,
            servings: 2,
            rating: 4,
            wouldRepeat: true,
            note: note,
            startedAt: t0
        )
    }

    // MARK: The pair

    func testEventMirrorsTheCookRecord() throws {
        let handoff = try makeHandoff(session: makeFinishedSession())
        XCTAssertEqual(handoff.event.kind, .cookCompleted)
        XCTAssertEqual(handoff.event.source, .appObserved)
        XCTAssertEqual(handoff.event.rating, handoff.cook.rating)
        XCTAssertEqual(handoff.event.note, handoff.cook.note)
        XCTAssertEqual(handoff.event.recipeRevision, handoff.cook.recipeRevision)
        XCTAssertEqual(handoff.event.timestamp, handoff.cook.completedAt)
        XCTAssertEqual(handoff.cook.servings, 2)
        XCTAssertEqual(handoff.cook.rating, 4)
    }

    func testCommitRefusesUnfinishedSession() throws {
        let revision = TestBuilders.revision(
            "galette",
            lines: [TestBuilders.line("l1", "flour", TestBuilders.grams(250))]
        )
        let cooking = try CookSession.start(sessionID: "sess-1", revision: revision, now: t0)
        XCTAssertThrowsError(try makeHandoff(session: cooking)) { error in
            guard case let FLFlowError.mealLogRefused(reason) = error else {
                return XCTFail("expected mealLogRefused, got \(error)")
            }
            XCTAssertTrue(reason.contains("finished session"))
        }
    }

    // MARK: Atomic commitment

    func testCommitWritesBothRowsAndDecodesBackThroughValidatedDecoders() throws {
        let db = try makeDatabase()
        let handoff = try makeHandoff(session: makeFinishedSession())
        try MealLog.commit(handoff, db: db)

        let cooks = try MealLog.cooks(db: db)
        let events = try MealLog.cookCompletedEvents(db: db)
        XCTAssertEqual(cooks.count, 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(cooks.first, handoff.cook)
        XCTAssertEqual(events.first, handoff.event)
    }

    func testEventInsertFailureRollsBackTheCookRow() throws {
        // The atomicity proof: a second hand-off reusing the first event's
        // ID hits the primary key on the event insert; the cook row of that
        // same transaction must roll back with it.
        let db = try makeDatabase()
        let first = try makeHandoff(session: makeFinishedSession(), cookID: "cook-1", eventID: "evt-1")
        try MealLog.commit(first, db: db)

        let second = try makeHandoff(session: makeFinishedSession(), cookID: "cook-2", eventID: "evt-1")
        XCTAssertThrowsError(try MealLog.commit(second, db: db))

        XCTAssertEqual(try MealLog.cooks(db: db).count, 1, "the second cook row must roll back with its event")
        XCTAssertEqual(try MealLog.cooks(db: db).first?.id, "cook-1")
        XCTAssertEqual(try MealLog.cookCompletedEvents(db: db).count, 1)
    }

    func testDuplicateCookIDIsRefusedAndLeavesOneRow() throws {
        let db = try makeDatabase()
        let first = try makeHandoff(session: makeFinishedSession(), cookID: "cook-1", eventID: "evt-1")
        try MealLog.commit(first, db: db)

        let second = try makeHandoff(session: makeFinishedSession(), cookID: "cook-1", eventID: "evt-2")
        XCTAssertThrowsError(try MealLog.commit(second, db: db))
        XCTAssertEqual(try MealLog.cooks(db: db).count, 1)
        XCTAssertEqual(try MealLog.cookCompletedEvents(db: db).count, 1, "the event of the refused transaction must roll back too")
    }

    // MARK: Migrations

    func testFlowMigrationsComposeWithTheBaselineAndAreIdempotent() throws {
        let db = try makeDatabase()
        try db.migrate() // the FLPersistence baseline ("v1-baseline")
        try FlowMigrations.apply(to: db.dbWriter)
        try FlowMigrations.apply(to: db.dbWriter) // idempotent

        XCTAssertTrue(try db.tableExists("fl_schema_baseline"))
        XCTAssertTrue(try db.tableExists("flflow_cooks"))
        XCTAssertTrue(try db.tableExists("flflow_preference_events"))
        // FLPersistence's appliedMigrations() reports the baseline
        // migrator's IDs only (Part 1 owns that API — recorded in the PR
        // handoff); the GRDB registry itself is the ground truth for
        // composition and ordering.
        let registry = try registryIDs(db)
        XCTAssertEqual(registry.first, "v1-baseline", "the baseline must be applied before the flow migration")
        XCTAssertTrue(registry.contains("v2-flflow-meallog"))
    }

    /// Applied migration IDs, in apply order, straight from GRDB's registry.
    private func registryIDs(_ db: AppDatabase) throws -> [String] {
        try db.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    // MARK: Recovery into the hand-off (restart end to end)

    func testRecoveredFinishedCheckpointCommitsAsOneTransaction() throws {
        let db = try makeDatabase()
        try FlowMigrations.apply(to: db.dbWriter)
        let finished = try makeFinishedSession()

        // A restart holds only the bare checkpoint; recovery decides, then
        // the hand-off commits.
        let decision = try CookSession.recover(
            checkpoint: finished.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(1300),
            policy: .standard
        )
        XCTAssertEqual(decision, .finished)
        let session = try CookSession.reinstate(
            checkpoint: finished.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(1300)
        )
        XCTAssertEqual(session.stage, .finished)
        let handoff = try makeHandoff(session: session)
        try MealLog.commit(handoff, db: db)
        XCTAssertEqual(try MealLog.cooks(db: db).count, 1)
        XCTAssertEqual(try MealLog.cookCompletedEvents(db: db).count, 1)
    }
}
