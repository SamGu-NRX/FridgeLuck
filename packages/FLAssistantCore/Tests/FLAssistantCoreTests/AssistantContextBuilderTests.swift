import XCTest
@testable import FLAssistantCore
import FLDomain

final class AssistantContextBuilderTests: XCTestCase {
    private let t0 = try! FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")

    /// A deterministic state source: fixed lines, recipe and step.
    private final class FakeStateSource: AssistantStateSource {
        let lines: [AssistantPantryLine]
        let recipe: RecipeKey?
        let step: Int?
        init(lines: [AssistantPantryLine], recipe: RecipeKey? = nil, step: Int? = nil) {
            self.lines = lines
            self.recipe = recipe
            self.step = step
        }
        func pantryLines() throws -> [AssistantPantryLine] { lines }
        func recipeContext() throws -> RecipeKey? { recipe }
        func currentStepIndex() throws -> Int? { step }
    }

    private func line(
        _ name: String,
        quantity: QuantityEvidence,
        confirmedAt: Date? = nil
    ) -> AssistantPantryLine {
        AssistantPantryLine(canonicalName: name, quantity: quantity, lastConfirmedAt: confirmedAt)
    }

    private func makeBuilder(
        _ source: AssistantStateSource,
        clock: AssistantRevisionClock? = nil
    ) throws -> AssistantContextBuilder {
        let revisionClock = try clock ?? AssistantRevisionClock()
        return AssistantContextBuilder(stateSource: source, revisionClock: revisionClock)
    }

    // MARK: Revision clock

    func testRevisionClockStartsAtOneAndBumpsStrictly() async throws {
        let clock = try AssistantRevisionClock()
        let first = await clock.current()
        XCTAssertEqual(first, 1)
        let bumped = await clock.bump()
        XCTAssertEqual(bumped, 2)
        let after = await clock.current()
        XCTAssertEqual(after, 2)
        // Reading again without a state change does not inflate the revision.
        let again = await clock.current()
        XCTAssertEqual(again, 2)
    }

    func testRevisionClockRejectsBelowFloor() {
        XCTAssertThrowsError(try AssistantRevisionClock(revision: 0)) { error in
            XCTAssertEqual(error as? FLAssistantError, .revisionBelowFloor(value: 0))
        }
    }

    func testConcurrentBumpsSerializeWithoutRegression() async throws {
        let clock = try AssistantRevisionClock()
        // 200 concurrent bumps: the actor serializes them, so exactly 200
        // distinct revisions appear and none ever decreases.
        let results = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<200 {
                group.addTask { await clock.bump() }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(results).count, 200, "every bump must mint a distinct revision")
        let final = await clock.current()
        XCTAssertEqual(final, 201)
    }

    // MARK: Builder

    func testBuildSnapshotCarriesUnknownQuantityEvidenceAsUnknown() async throws {
        let builder = try makeBuilder(FakeStateSource(lines: [
            line("flour", quantity: .weighedGrams(try GramMass(grams: 500)), confirmedAt: t0),
            line("maple syrup", quantity: .unknown, confirmedAt: t0),
            line("scallions", quantity: .unknown, confirmedAt: nil),
        ]))
        let snapshot = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        XCTAssertEqual(snapshot.pantrySummary.count, 3)
        // Unknown evidence reaches the model as unknown — never a number.
        XCTAssertTrue(snapshot.pantrySummary[1].quantity.isUnknown)
        XCTAssertNil(snapshot.pantrySummary[1].quantity.gramsIfKnown)
        XCTAssertTrue(snapshot.pantrySummary[2].quantity.isUnknown)
        XCTAssertNil(snapshot.pantrySummary[2].lastConfirmedAt)
        // Known evidence is carried verbatim.
        XCTAssertEqual(snapshot.pantrySummary[0].quantity.gramsIfKnown?.grams, 500)
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.capturedAt, t0)
    }

    func testSnapshotRevisionFollowsStateChangesMonotonically() async throws {
        let clock = try AssistantRevisionClock()
        let builder = try makeBuilder(FakeStateSource(lines: []), clock: clock)
        let first = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        let second = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        // No state change between builds: same revision, proposals stay valid.
        XCTAssertEqual(first.revision, second.revision)
        _ = await clock.bump()  // the host's state-mutation path
        let third = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        XCTAssertGreaterThan(third.revision, second.revision)
        _ = await clock.bump()
        let fourth = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        XCTAssertGreaterThan(fourth.revision, third.revision)
    }

    func testSnapshotNeverRegressesAcrossManyStateChanges() async throws {
        let clock = try AssistantRevisionClock()
        let builder = try makeBuilder(
            FakeStateSource(lines: [line("eggs", quantity: .unknown)]), clock: clock
        )
        var last = 0
        for _ in 0..<25 {
            let snapshot = try await builder.buildSnapshot(sessionID: "s1", now: t0)
            XCTAssertGreaterThanOrEqual(snapshot.revision, last, "revision regressed")
            last = snapshot.revision
            _ = await clock.bump()
        }
    }

    func testPantrySummaryCapKeepsProviderOrder() async throws {
        let many = (0..<100).map { line("item-\($0)", quantity: .unknown) }
        let builder = AssistantContextBuilder(
            stateSource: FakeStateSource(lines: many),
            revisionClock: try AssistantRevisionClock(),
            maxPantryLines: 10
        )
        let snapshot = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        XCTAssertEqual(snapshot.pantrySummary.count, 10, "the snapshot must stay bounded")
        // The cap keeps the provider's own relevance order — no reordering.
        XCTAssertEqual(snapshot.pantrySummary.map(\.canonicalName), (0..<10).map { "item-\($0)" })
    }

    func testSnapshotCarriesRecipeContextAndStepIndex() async throws {
        let recipe = try RecipeKey(source: .catalog, sourceRecipeID: "pancakes", revision: 3)
        let builder = try makeBuilder(FakeStateSource(lines: [], recipe: recipe, step: 2))
        let snapshot = try await builder.buildSnapshot(sessionID: "s1", now: t0)
        XCTAssertEqual(snapshot.recipeContext, recipe)
        XCTAssertEqual(snapshot.stepIndex, 2)
    }

    func testSnapshotRejectsEmptySessionID() async throws {
        let builder = try makeBuilder(FakeStateSource(lines: []))
        // FLDomain's validated constructor refuses an empty session ID; the
        // builder does not weaken domain validation.
        do {
            _ = try await builder.buildSnapshot(sessionID: "   ", now: t0)
            XCTFail("expected an empty-session-ID refusal")
        } catch {
            // Expected: FLDomain validation, unchanged by this layer.
        }
    }
}
