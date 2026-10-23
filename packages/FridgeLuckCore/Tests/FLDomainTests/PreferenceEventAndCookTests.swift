import XCTest
@testable import FLDomain

final class PreferenceEventAndCookTests: XCTestCase {
    private let revision = try! RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)
    private let t0 = try! FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
    private let t1 = try! FLTimestamp.decode("2026-10-11T12:30:00.000Z", target: "test")
    private let onion = try! IngredientReference(canonicalName: "onion")
    private let shallot = try! IngredientReference(canonicalName: "shallot")

    // MARK: PreferenceEvent

    func testCookCompletedRequiresRatingAndWouldRepeat() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e1", kind: .cookCompleted, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, rating: 4
            )
        )
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e1", kind: .cookCompleted, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, wouldRepeat: true
            )
        )
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e1", kind: .cookCompleted, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, rating: 6, wouldRepeat: true
            )
        )
        XCTAssertNoThrow(
            try PreferenceEvent(
                id: "e1", kind: .cookCompleted, timestamp: t0, recipeRevision: revision,
                source: .appObserved, rating: 4, wouldRepeat: true, note: "kids loved it"
            )
        )
    }

    func testCookCompletedNoteIsOneLine() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e1", kind: .cookCompleted, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, rating: 4, wouldRepeat: true, note: "line one\nline two"
            )
        )
    }

    func testIngredientRemovedRequiresName() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(id: "e2", kind: .ingredientRemoved, timestamp: t0, recipeRevision: revision, source: .userExplicit)
        )
        let event = try PreferenceEvent(
            id: "e2", kind: .ingredientRemoved, timestamp: t0, recipeRevision: revision,
            source: .userExplicit, ingredientName: "cilantro"
        )
        XCTAssertEqual(event.ingredientName, "cilantro")
    }

    func testSubstitutedRequiresDistinctIngredients() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(id: "e3", kind: .substituted, timestamp: t0, recipeRevision: revision, source: .appObserved)
        )
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e3", kind: .substituted, timestamp: t0, recipeRevision: revision,
                source: .appObserved, fromIngredient: onion, toIngredient: onion
            )
        )
        let event = try PreferenceEvent(
            id: "e3", kind: .substituted, timestamp: t0, recipeRevision: revision,
            source: .appObserved, fromIngredient: onion, toIngredient: shallot
        )
        XCTAssertEqual(event.fromIngredient, onion)
        XCTAssertEqual(event.toIngredient, shallot)
    }

    func testProfileEditRequiresSentenceAndVerdict() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e4", kind: .profileEdit, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, verdict: .confirmed
            )
        )
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e4", kind: .profileEdit, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, sentenceID: "s-dairy"
            )
        )
        XCTAssertNoThrow(
            try PreferenceEvent(
                id: "e4", kind: .profileEdit, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, sentenceID: "s-dairy", verdict: .corrected
            )
        )
    }

    func testEventCannotSupersedeItself() {
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e5", kind: .opened, timestamp: t0, recipeRevision: revision,
                source: .userExplicit,
                supersedes: EventCorrection(
                    priorEventID: try! PreferenceEventID("e5"),
                    mode: .retracts
                )
            )
        )
    }

    func testExposureIDMustBeNonEmptyWhenPresent() throws {
        XCTAssertThrowsError(
            try PreferenceEvent(
                id: "e6", kind: .opened, timestamp: t0, recipeRevision: revision,
                source: .userExplicit, exposureID: "   "
            )
        )
        XCTAssertNoThrow(
            try PreferenceEvent(
                id: "e6", kind: .exposed, timestamp: t0, recipeRevision: revision,
                source: .appObserved, exposureID: "x-1"
            )
        )
    }

    /// Round trip preserves every field, including the correction reference and
    /// kind-specific payload.
    func testEventRoundTripWithCorrection() throws {
        let correction = try PreferenceEvent(
            id: "e7", kind: .cookCompleted, timestamp: t1, recipeRevision: revision,
            source: .userExplicit,
            supersedes: EventCorrection(priorEventID: try PreferenceEventID("e6"), mode: .corrects),
            rating: 2,
            wouldRepeat: false,
            note: "was too salty"
        )
        let decoded = try FLJSON.canonicalDecoder().decode(PreferenceEvent.self, from: FLJSON.canonicalData(correction))
        XCTAssertEqual(decoded, correction)
        XCTAssertEqual(decoded.supersedes?.priorEventID.rawValue, "e6")
        XCTAssertEqual(decoded.supersedes?.mode, .corrects)
    }

    func testEventUnknownKindFailsToDecode() throws {
        let json = """
        {"id":"e8","kind":"hovered","timestamp":"2026-10-11T12:00:00.000Z",
         "recipeRevision":{"source":"user","sourceRecipeID":"pancakes","revision":1},"source":"userExplicit"}
        """
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(PreferenceEvent.self, from: Data(json.utf8)))
    }

    /// A cookCompleted fixture missing wouldRepeat is rejected at the boundary,
    /// not silently accepted and patched later.
    func testEventDecodeRunsKindValidation() throws {
        let json = """
        {"id":"e9","kind":"cookCompleted","timestamp":"2026-10-11T12:00:00.000Z",
         "recipeRevision":{"source":"user","sourceRecipeID":"pancakes","revision":1},
         "source":"userExplicit","rating":4}
        """
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(PreferenceEvent.self, from: Data(json.utf8)))
    }

    // MARK: PreferenceEventID

    func testEventIDValidation() {
        XCTAssertThrowsError(try PreferenceEventID("   "))
        XCTAssertThrowsError(try PreferenceEventID(String(repeating: "x", count: 129)))
        XCTAssertNoThrow(try PreferenceEventID("evt-001"))
    }

    // MARK: Cook

    func testCookValidation() throws {
        XCTAssertThrowsError(try Cook(id: "", recipeRevision: revision, servings: 2, rating: 4, completedAt: t0))
        XCTAssertThrowsError(try Cook(id: "c1", recipeRevision: revision, servings: 0, rating: 4, completedAt: t0))
        XCTAssertThrowsError(try Cook(id: "c1", recipeRevision: revision, servings: 2, rating: 9, completedAt: t0))
        XCTAssertThrowsError(try Cook(id: "c1", recipeRevision: revision, servings: 2, rating: 4, note: "a\nb", completedAt: t0))
        // startedAt after completedAt is inconsistent.
        XCTAssertThrowsError(try Cook(id: "c1", recipeRevision: revision, servings: 2, rating: 4, startedAt: t1, completedAt: t0))
    }

    func testCookRoundTrip() throws {
        let cook = try Cook(
            id: "c2", recipeRevision: revision, servings: 3,
            substitutions: [try CookSubstitution(from: onion, to: shallot, necessity: .necessary)],
            rating: 5, note: "kids loved it", startedAt: t0, completedAt: t1
        )
        let decoded = try FLJSON.canonicalDecoder().decode(Cook.self, from: FLJSON.canonicalData(cook))
        XCTAssertEqual(decoded, cook)
        // completedAt is encoded in the canonical timestamp form.
        let text = String(data: try FLJSON.canonicalData(cook), encoding: .utf8)!
        XCTAssertTrue(text.contains(#""completedAt" : "2026-10-11T12:30:00.000Z""#))
    }

    func testCookSubstitutionSelfSwapRejected() {
        XCTAssertThrowsError(try CookSubstitution(from: onion, to: onion, necessity: .preferred))
    }
}
