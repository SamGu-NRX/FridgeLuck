import XCTest
import FLDomain
@testable import FLCommunityCore

/// Taste-profile sentence editing: every verdict is a PreferenceEvent
/// (kind: profileEdit, sentenceID, verdict); a later edit supersedes the
/// effective one; "this is wrong" (rejected) is retired until reopened; a
/// mistaken event is removed by retraction. The state of a sentence is
/// always replayable from its history. SPEC 3.3.
final class ProfileEditEventTests: XCTestCase {
    private func sentence(state: ProfileSentence.State = .open) throws -> ProfileSentence {
        let base = try TestSupport.profileSentence()
        return try ProfileSentence(
            sentenceID: base.sentenceID,
            text: base.text,
            layer: base.layer,
            evidence: base.evidence,
            evidenceRevision: base.evidenceRevision,
            state: state
        )
    }

    // MARK: Recording verdicts

    func testConfirmedVerdictRecordsProfileEditEvent() throws {
        let s = try sentence()
        let recording = try ProfileEditRecorder.record(
            verdict: .confirmed,
            sentence: s,
            eventID: "pe-001",
            at: try TestSupport.date("2026-10-03T10:00:00.000Z"),
            history: []
        )
        XCTAssertEqual(recording.event.kind, .profileEdit)
        XCTAssertEqual(recording.event.sentenceID, "sentence-coriander-removal")
        XCTAssertEqual(recording.event.verdict, .confirmed)
        XCTAssertNil(recording.event.supersedes)
        XCTAssertEqual(recording.event.source, .userExplicit)
        XCTAssertEqual(recording.sentence.state, .confirmed)
        // The event replays back to exactly that state.
        let replayed = try ProfileEditRecorder.replayState(of: s, history: [recording.event])
        XCTAssertEqual(replayed.state, .confirmed)
        XCTAssertEqual(replayed.effectiveEvent, recording.event)
    }

    func testCorrectedVerdictSupersedesThePriorEvent() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let recording = try ProfileEditRecorder.record(
            verdict: .corrected,
            sentence: s,
            eventID: "pe-002",
            at: try TestSupport.date("2026-10-04T10:00:00.000Z"),
            history: [first]
        )
        XCTAssertEqual(recording.event.supersedes, try TestSupport.correction("pe-001", .corrects))
        XCTAssertEqual(recording.sentence.state, .corrected)
        // Full history replays to the newest state.
        let replayed = try ProfileEditRecorder.replayState(of: s, history: [first, recording.event])
        XCTAssertEqual(replayed.state, .corrected)
    }

    func testRejectedThenReopenThenConfirmed() throws {
        let s = try sentence()
        let reject = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .rejected, at: "2026-10-03T10:00:00.000Z")
        let reopen = try ProfileEditRecorder.record(
            verdict: .reopened,
            sentence: s,
            eventID: "pe-002",
            at: try TestSupport.date("2026-10-05T10:00:00.000Z"),
            history: [reject]
        )
        XCTAssertEqual(reopen.event.supersedes, try TestSupport.correction("pe-001", .corrects))
        XCTAssertEqual(reopen.sentence.state, .reopened)
        let confirm = try ProfileEditRecorder.record(
            verdict: .confirmed,
            sentence: s,
            eventID: "pe-003",
            at: try TestSupport.date("2026-10-06T10:00:00.000Z"),
            history: [reject, reopen.event]
        )
        XCTAssertEqual(confirm.event.supersedes, try TestSupport.correction("pe-002", .corrects))
        XCTAssertEqual(confirm.sentence.state, .confirmed)
    }

    func testCorrectingARejectedSentenceThrows() throws {
        let s = try sentence(state: .rejected)
        XCTAssertThrowsError(try ProfileEditRecorder.record(
            verdict: .corrected, sentence: s, eventID: "pe-009",
            at: try TestSupport.date("2026-10-04T10:00:00.000Z"), history: []
        )) { error in
            guard case let FLDomainError.validation(target, reason) = error else { return XCTFail("wrong error type") }
            XCTAssertEqual(target, "ProfileEditRecorder.verdict")
            XCTAssertTrue(reason.contains("reopen"))
        }
    }

    func testReopenOnALiveSentenceThrows() throws {
        let s = try sentence(state: .confirmed)
        XCTAssertThrowsError(try ProfileEditRecorder.record(
            verdict: .reopened, sentence: s, eventID: "pe-009",
            at: try TestSupport.date("2026-10-04T10:00:00.000Z"), history: []
        ))
    }

    // MARK: Retraction removes a mistaken event

    func testRetractRestoresTheInitialState() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let recording = try ProfileEditRecorder.retract(
            eventIDToRetract: "pe-001",
            eventID: "pe-002",
            sentence: s,
            at: try TestSupport.date("2026-10-04T10:00:00.000Z"),
            history: [first]
        )
        XCTAssertEqual(recording.event.supersedes, try TestSupport.correction("pe-001", .retracts))
        XCTAssertEqual(recording.sentence.state, .open)
        let replayed = try ProfileEditRecorder.replayState(of: s, history: [first, recording.event])
        XCTAssertEqual(replayed.state, .open)
        XCTAssertNil(replayed.effectiveEvent, "a retraction leaves no effective event")
    }

    func testRetractRestoresTheStateUnderneath() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let second = try TestSupport.profileEvent(
            "pe-002", sentence: s, verdict: .rejected, at: "2026-10-04T10:00:00.000Z",
            supersedes: try TestSupport.correction("pe-001", .corrects)
        )
        let recording = try ProfileEditRecorder.retract(
            eventIDToRetract: "pe-002",
            eventID: "pe-003",
            sentence: s,
            at: try TestSupport.date("2026-10-05T10:00:00.000Z"),
            history: [first, second]
        )
        XCTAssertEqual(recording.sentence.state, .confirmed, "the confirmed verdict underneath becomes effective again")
    }

    func testRetractOfNonEffectiveEventThrows() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let second = try TestSupport.profileEvent(
            "pe-002", sentence: s, verdict: .corrected, at: "2026-10-04T10:00:00.000Z",
            supersedes: try TestSupport.correction("pe-001", .corrects)
        )
        XCTAssertThrowsError(try ProfileEditRecorder.retract(
            eventIDToRetract: "pe-001", // no longer effective; it was corrected
            eventID: "pe-003",
            sentence: s,
            at: try TestSupport.date("2026-10-05T10:00:00.000Z"),
            history: [first, second]
        ))
    }

    func testRetractWithNoHistoryThrows() throws {
        XCTAssertThrowsError(try ProfileEditRecorder.retract(
            eventIDToRetract: "pe-001", eventID: "pe-002",
            sentence: try sentence(),
            at: try TestSupport.date("2026-10-04T10:00:00.000Z"), history: []
        ))
    }

    // MARK: Ledger validation (replay refuses what it cannot explain)

    func testBrokenChainThrows() throws {
        let s = try sentence()
        let orphan = try TestSupport.profileEvent(
            "pe-002", sentence: s, verdict: .corrected, at: "2026-10-04T10:00:00.000Z",
            supersedes: try TestSupport.correction("pe-999", .corrects)
        )
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [orphan]))
        XCTAssertThrowsError(try ProfileEditRecorder.record(
            verdict: .confirmed, sentence: s, eventID: "pe-003",
            at: try TestSupport.date("2026-10-05T10:00:00.000Z"), history: [orphan]
        ))
    }

    func testChainWithoutSupersessionAfterTheFirstThrows() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let second = try TestSupport.profileEvent("pe-002", sentence: s, verdict: .corrected, at: "2026-10-04T10:00:00.000Z")
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [first, second])) { error in
            guard case let FLDomainError.validation(_, reason) = error else { return XCTFail("wrong error type") }
            XCTAssertTrue(reason.contains("still effective"))
        }
    }

    func testDuplicateEventIDThrows() throws {
        let s = try sentence()
        let first = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        let copy = try TestSupport.profileEvent("pe-001", sentence: s, verdict: .confirmed, at: "2026-10-03T10:00:00.000Z")
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [first, copy]))
    }

    func testEventForAnotherSentenceThrows() throws {
        let s = try sentence()
        let other = try PreferenceEvent(
            id: "pe-other", kind: .profileEdit,
            timestamp: try TestSupport.date("2026-10-03T10:00:00.000Z"),
            recipeRevision: s.evidenceRevision,
            source: .userExplicit,
            sentenceID: "sentence-someone-else",
            verdict: .confirmed
        )
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [other]))
    }

    func testEventAnchoredToAnotherRevisionThrows() throws {
        let s = try sentence()
        let other = try PreferenceEvent(
            id: "pe-anchor", kind: .profileEdit,
            timestamp: try TestSupport.date("2026-10-03T10:00:00.000Z"),
            recipeRevision: RecipeKey(source: .user, sourceRecipeID: "other-anchor", revision: 2),
            source: .userExplicit,
            sentenceID: s.sentenceID,
            verdict: .confirmed
        )
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [other]))
    }

    func testNonProfileEditEventThrows() throws {
        let s = try sentence()
        let saved = try PreferenceEvent(
            id: "pe-saved", kind: .saved,
            timestamp: try TestSupport.date("2026-10-03T10:00:00.000Z"),
            recipeRevision: s.evidenceRevision,
            source: .userExplicit
        )
        XCTAssertThrowsError(try ProfileEditRecorder.replayState(of: s, history: [saved]))
    }

    // MARK: Sentence validation

    func testSentenceValidation() throws {
        XCTAssertThrowsError(try ProfileSentence(
            sentenceID: "  ", text: "x", layer: .inferredTaste,
            evidence: "e", evidenceRevision: RecipeKey(source: .user, sourceRecipeID: "k", revision: 1)
        ))
        XCTAssertThrowsError(try ProfileSentence(
            sentenceID: "s", text: "  ", layer: .inferredTaste,
            evidence: "e", evidenceRevision: RecipeKey(source: .user, sourceRecipeID: "k", revision: 1)
        ))
        XCTAssertThrowsError(try ProfileSentence(
            sentenceID: "s", text: "t", layer: .inferredTaste,
            evidence: "   ", evidenceRevision: RecipeKey(source: .user, sourceRecipeID: "k", revision: 1)
        ), "a sentence without evidence is not shown")
        XCTAssertThrowsError(try ProfileSentence(
            sentenceID: String(repeating: "s", count: 129), text: "t", layer: .inferredTaste,
            evidence: "e", evidenceRevision: RecipeKey(source: .user, sourceRecipeID: "k", revision: 1)
        ))
    }

    func testSentenceRoundTripsThroughCanonicalJSON() throws {
        let s = try sentence()
        let data = try FLJSON.canonicalData(s)
        let decoded = try FLJSON.canonicalDecoder().decode(ProfileSentence.self, from: data)
        XCTAssertEqual(decoded, s)
        XCTAssertEqual(try FLJSON.canonicalData(decoded), data)
    }
}
