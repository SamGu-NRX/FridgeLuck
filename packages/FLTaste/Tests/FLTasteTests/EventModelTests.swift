import XCTest
@testable import FLTaste

/// Event-model behaviour: idempotency, order independence, corrections,
/// explicit layers. Tests observe folded state, never fold internals.
final class EventModelTests: XCTestCase {
    func testDuplicateEventIDReplayIsNoOp() {
        var engine = Fixtures.engine()
        let events = Fixtures.scenarioEvents()
        engine.ingest(events)
        let firstState = engine.state
        let firstCount = engine.eventCount

        // Replaying the same events (and a same-ID event with different
        // content) changes nothing.
        engine.ingest(events)
        let mutated = Fixtures.cooked(
            "c1", "r_chili_rice", at: Fixtures.instant(50), rating: Rating(1))
        engine.ingest(mutated)

        XCTAssertEqual(engine.state, firstState)
        XCTAssertEqual(engine.eventCount, firstCount)
        XCTAssertEqual(engine.events.count, events.count, "duplicate must not append to the log")
    }

    func testIngestOrderDoesNotMatter() throws {
        var a = Fixtures.engine()
        var b = Fixtures.engine()
        let events = Fixtures.scenarioEvents()
        a.ingest(events)
        b.ingest(events.reversed())
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(try a.snapshotJSON(), try b.snapshotJSON())
    }

    func testFoldInvariantHoldsAfterEveryIngest() {
        var engine = Fixtures.engine()
        let events = Fixtures.scenarioEvents()
        for event in events {
            engine.ingest(event)
            XCTAssertEqual(engine.state, Fold.apply(engine.events))
        }
    }

    func testCorrectionCanSetRatingAfterTheFact() {
        var engine = Fixtures.engine()
        engine.ingest([
            Fixtures.cooked("c1", "r_rice_bowl", at: Fixtures.instant(1), rating: Rating(2), eater: "sam"),
        ])
        let before = engine.state.eaters[EaterID("sam")!]? .recipeHistory[RecipeID("r_rice_bowl")!]?.cooks.first?.rating
        XCTAssertEqual(before, Rating(2))

        engine.ingest([
            Fixtures.correction("x1", amends: "c1", .setRating(Rating(5)!), at: Fixtures.instant(2)),
        ])
        let cooks = engine.state.eaters[EaterID("sam")!]? .recipeHistory[RecipeID("r_rice_bowl")!]?.cooks
        XCTAssertEqual(cooks?.count, 1)
        XCTAssertEqual(cooks?.first?.rating, Rating(5), "correction must replace the rating")
    }

    func testVoidedEventContributesNothingButStaysIdempotent() {
        var engine = Fixtures.engine()
        engine.ingest([
            Fixtures.cooked("c1", "r_rice_bowl", at: Fixtures.instant(1), rating: Rating(5), eater: "sam"),
            Fixtures.correction("x1", amends: "c1", .void, at: Fixtures.instant(2)),
        ])
        let cooks = engine.state.eaters[EaterID("sam")!]? .recipeHistory[RecipeID("r_rice_bowl")!]?.cooks.count
        XCTAssertEqual(cooks ?? 0, 0, "voided cook must not be recorded")
        XCTAssertEqual(engine.eventCount, 2, "voided event stays seen")
        // Replaying the pair stays a no-op.
        let before = engine.state
        engine.ingest(Fixtures.correction("x1", amends: "c1", .void, at: Fixtures.instant(2)))
        XCTAssertEqual(engine.state, before)
    }

    /// Voiding a CORRECTION inerts the correction (the original event stands
    /// as amended by any other corrections); voiding that void revives the
    /// correction. Changing your mind never requires a full reset.
    func testVoidingACorrectionInertsItAndVoidingTheVoidRevivesIt() {
        var engine = Fixtures.engine()
        engine.ingest([
            Fixtures.cooked("c1", "r_rice_bowl", at: Fixtures.instant(1), rating: Rating(2), eater: "sam"),
            Fixtures.correction("x1", amends: "c1", .setRating(Rating(5)!), at: Fixtures.instant(2)),
            Fixtures.correction("x2", amends: "x1", .void, at: Fixtures.instant(3)),
        ])
        let inert = engine.state.eaters[EaterID("sam")!]? .recipeHistory[RecipeID("r_rice_bowl")!]?.cooks.first?.rating
        XCTAssertEqual(inert, Rating(2), "voided correction must leave the original rating")

        // Un-voiding (voiding the void) revives the correction.
        engine.ingest(Fixtures.correction("x3", amends: "x2", .void, at: Fixtures.instant(4)))
        let revived = engine.state.eaters[EaterID("sam")!]? .recipeHistory[RecipeID("r_rice_bowl")!]?.cooks.first?.rating
        XCTAssertEqual(revived, Rating(5), "voiding the void revives the correction")
    }

    func testReattributeMovesCookToAnotherEater() {
        var engine = Fixtures.engine()
        engine.ingest(Fixtures.scenarioEvents())
        let sam = engine.state.eaters[EaterID("sam")!]
        let lena = engine.state.eaters[EaterID("lena")!]
        let samCilantro = sam? .recipeHistory[RecipeID("r_cilantro_chicken")!]?.cooks.count ?? 0
        let lenaCilantro = lena? .recipeHistory[RecipeID("r_cilantro_chicken")!]?.cooks.count ?? 0
        XCTAssertEqual(samCilantro, 1, "reattribution moves the cook to sam")
        XCTAssertEqual(lenaCilantro, 0, "reattribution removes it from lena")
    }

    func testDanglingCorrectionBecomesDiagnosticNotThrow() {
        var engine = Fixtures.engine()
        engine.ingest([
            Fixtures.correction("x1", amends: "missing", .setRating(Rating(3)!), at: Fixtures.instant(1)),
        ])
        XCTAssertEqual(engine.eventCount, 1)
        XCTAssertEqual(engine.state.diagnostics.count, 1)
        XCTAssertEqual(engine.state.diagnostics.first?.eventID, EventID("x1"))
    }

    func testRestrictionsLandInHouseholdAndEaterLayers() {
        var engine = Fixtures.engine()
        engine.ingest([
            Fixtures.profileEdit(
                "p1",
                .setRestriction(Restriction(kind: .allergy, target: "peanut_butter", source: "setup")),
                at: Fixtures.instant(0)),
            Fixtures.profileEdit(
                "p2",
                .setRestriction(Restriction(kind: .diet, target: "shellfish", source: "setup")),
                at: Fixtures.instant(0), eater: "lena"),
        ])
        XCTAssertEqual(engine.state.household.restrictions.map(\.target), ["peanut_butter"])
        XCTAssertEqual(engine.state.eaters[EaterID("lena")!]? .explicit.restrictions.map(\.target), ["shellfish"])
    }

    func testTimestampsAreUTCAndOrdered() {
        let event = Fixtures.cooked("c1", "r_rice_bowl", at: Fixtures.instant(1, 13, 30))
        XCTAssertEqual(event.at.iso8601UTC, "2026-01-02T13:30:00Z")
        XCTAssertEqual(
            event.at.millisecondsSinceEpoch,
            Fixtures.baseMillis + 86_400_000 + 13 * 3_600_000 + 30 * 60_000)
    }

    func testExposureValidation() {
        XCTAssertThrowsError(try ExposureContext(feasibleCandidates: 0, shownCandidates: nil))
        XCTAssertThrowsError(try ExposureContext(feasibleCandidates: 3, shownCandidates: 5))
        XCTAssertNoThrow(try ExposureContext(feasibleCandidates: 3, shownCandidates: nil))
        XCTAssertNoThrow(try ExposureContext(feasibleCandidates: 3, shownCandidates: 3))
    }
}
