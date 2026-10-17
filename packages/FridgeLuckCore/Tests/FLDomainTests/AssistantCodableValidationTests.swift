import XCTest
@testable import FLDomain

/// Review round 1, items 1 and 2: decoders must never bypass validation, and
/// every `Date` must travel through the canonical FLTimestamp ISO 8601 form.
///
/// Each test here is a rejection test written against the SYNTHESIZED-Codable
/// behaviour: on the unfixed code the decode succeeds (or the encode emits a
/// bare epoch number) and the test fails. After the fix, every decode of an
/// invalid wire form throws and every encode emits ISO 8601 strings.
final class AssistantCodableValidationTests: XCTestCase {
    /// 64 lowercase hex characters — the only accepted payload-hash shape.
    private static let validHash = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"
    /// What the synthesized deferredToDate encoder produced for
    /// 2026-10-11T12:00:00.000Z (seconds since the 2001 reference epoch).
    private static let epochLeak = 813412800.0

    private let decoder = FLJSON.canonicalDecoder()

    // MARK: - ActionProposal decode-time validation

    private func proposalJSON(
        id: String = "p1",
        tool: String = "proposeStepAdvance",
        payload: String = #"{"kind":"stepAdvance","stepIndex":2}"#,
        payloadHash: String,
        snapshotRevision: Int,
        createdAt: String = "\"2026-10-11T12:00:00.000Z\"",
        expiresAt: String = "null"
    ) -> Data {
        Data("""
        {"createdAt":\(createdAt),"expiresAt":\(expiresAt),"id":"\(id)","payload":\(payload),"payloadHash":"\(payloadHash)","snapshotRevision":\(snapshotRevision),"tool":"\(tool)"}
        """.utf8)
    }

    func testProposalDecodeRejectsInvalidPayloadHash() throws {
        XCTAssertThrowsError(
            try decoder.decode(ActionProposal.self, from: proposalJSON(payloadHash: "deadbeef", snapshotRevision: 3)),
            "a short non-hex payload hash must not survive decoding"
        )
        XCTAssertThrowsError(
            try decoder.decode(ActionProposal.self, from: proposalJSON(payloadHash: Self.validHash.uppercased(), snapshotRevision: 3)),
            "an uppercase hash violates the lowercase-hex contract"
        )
    }

    func testProposalDecodeRejectsInvalidSnapshotRevision() {
        XCTAssertThrowsError(
            try decoder.decode(ActionProposal.self, from: proposalJSON(payloadHash: Self.validHash, snapshotRevision: 0)),
            "revision 0 must not survive decoding"
        )
        XCTAssertThrowsError(
            try decoder.decode(ActionProposal.self, from: proposalJSON(payloadHash: Self.validHash, snapshotRevision: -5))
        )
    }

    func testProposalDecodeRejectsNumericTimestamp() {
        // Item 2: the wire form must be an ISO 8601 string. A bare reference-
        // epoch number — what the synthesized encoder produced — is rejected.
        XCTAssertThrowsError(
            try decoder.decode(
                ActionProposal.self,
                from: proposalJSON(payloadHash: Self.validHash, snapshotRevision: 3, createdAt: "\(Self.epochLeak)")
            ),
            "a numeric createdAt contradicts the ISO 8601 contract and must be refused"
        )
    }

    func testProposalDecodeRejectsExpiryBeforeCreation() {
        XCTAssertThrowsError(
            try decoder.decode(
                ActionProposal.self,
                from: proposalJSON(
                    payloadHash: Self.validHash,
                    snapshotRevision: 3,
                    expiresAt: "\"2026-10-11T11:00:00.000Z\""
                )
            ),
            "expiresAt before createdAt must be refused at decode time"
        )
    }

    func testProposalDecodeRejectsContradictoryToolAndPayload() {
        // Item 7 (Assistant.swift:199): the pair is validated at construction,
        // and decoding constructs — so it is validated on the wire too.
        XCTAssertThrowsError(
            try decoder.decode(
                ActionProposal.self,
                from: proposalJSON(tool: "readPantry", payloadHash: Self.validHash, snapshotRevision: 3)
            ),
            "read tools do not produce proposals"
        )
        XCTAssertThrowsError(
            try decoder.decode(
                ActionProposal.self,
                from: proposalJSON(
                    tool: "proposeTimer",
                    payload: #"{"kind":"stepAdvance","stepIndex":2}"#,
                    payloadHash: Self.validHash,
                    snapshotRevision: 3
                )
            ),
            "a timer proposal carrying a step-advance payload is contradictory"
        )
        XCTAssertThrowsError(
            try decoder.decode(
                ActionProposal.self,
                from: proposalJSON(
                    tool: "proposeMealLog",
                    payload: #"{"kind":"stepAdvance","stepIndex":1}"#,
                    payloadHash: Self.validHash,
                    snapshotRevision: 3
                )
            )
        )
    }

    func testProposalConstructionRejectsContradictoryToolAndPayload() throws {
        let payload = ActionPayload.stepAdvance(stepIndex: 2)
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .readPantry, payload: payload,
                payloadHash: Self.validHash, snapshotRevision: 3,
                createdAt: FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
            )
        )
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .proposeTimer, payload: payload,
                payloadHash: Self.validHash, snapshotRevision: 3,
                createdAt: FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
            )
        )
        XCTAssertNoThrow(
            try ActionProposal(
                id: "p1", tool: .proposeStepAdvance, payload: payload,
                payloadHash: Self.validHash, snapshotRevision: 3,
                createdAt: FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
            )
        )
    }

    func testProposalEncodesTimestampsAsISOStrings() throws {
        let proposal = try ActionProposal(
            id: "p1", tool: .proposeStepAdvance, payload: .stepAdvance(stepIndex: 2),
            payloadHash: Self.validHash, snapshotRevision: 3,
            createdAt: FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test"),
            expiresAt: FLTimestamp.decode("2026-10-11T13:00:00.000Z", target: "test")
        )
        let raw = String(decoding: try FLJSON.canonicalData(proposal), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"createdAt\" : \"2026-10-11T12:00:00.000Z\""), "got: \(raw)")
        XCTAssertTrue(raw.contains("\"expiresAt\" : \"2026-10-11T13:00:00.000Z\""), "got: \(raw)")
        XCTAssertFalse(raw.contains("813412800"), "no bare reference-epoch numbers may appear; got: \(raw)")
    }

    // MARK: - ActionApproval decode-time validation

    func testApprovalDecodeRejectsInvalidHashAndRevision() {
        let json = { (hash: String, revision: Int) in
            Data("""
            {"approvedAt":"2026-10-11T12:05:00.000Z","payloadHash":"\(hash)","proposalID":"p1","snapshotRevision":\(revision)}
            """.utf8)
        }
        XCTAssertThrowsError(
            try decoder.decode(ActionApproval.self, from: json("tooshort", 3)),
            "an approval for a malformed hash must not survive decoding"
        )
        XCTAssertThrowsError(try decoder.decode(ActionApproval.self, from: json(Self.validHash, 0)))
        XCTAssertNoThrow(try decoder.decode(ActionApproval.self, from: json(Self.validHash, 3)))
    }

    // MARK: - ActionReceipt decode-time validation

    func testReceiptDecodeRejectsInvalidPayloadHashAndRevision() {
        let json = { (hash: String?, revision: Int?) in
            Data("""
            {"payloadHash":\(hash.map { "\"\($0)\"" } ?? "null"),"proposalID":"p1","recordedAt":"2026-10-11T12:05:00.000Z","snapshotRevision":\(revision.map(String.init) ?? "null"),"state":"executed"}
            """.utf8)
        }
        XCTAssertThrowsError(try decoder.decode(ActionReceipt.self, from: json("XYZ", 3)))
        XCTAssertThrowsError(try decoder.decode(ActionReceipt.self, from: json(Self.validHash, 0)))
        XCTAssertThrowsError(
            try decoder.decode(ActionReceipt.self, from: json(String(repeating: "a", count: 63), 3)),
            "63 hex characters is still not the 64-hex contract"
        )
        XCTAssertNoThrow(try decoder.decode(ActionReceipt.self, from: json(Self.validHash, 3)))
        // A receipt without a bound proposal keeps nil fields and stays valid.
        XCTAssertNoThrow(try decoder.decode(ActionReceipt.self, from: json(nil, nil)))
    }

    // MARK: - Checkpoint and timer decode-time validation

    func testTimerDecodeRejectsAcknowledgedWithoutDeviceCreation() {
        // Item 1: a timer marked acknowledged that the device never created
        // must not survive decoding.
        XCTAssertThrowsError(
            try decoder.decode(
                CookingSessionCheckpoint.TimerRecord.self,
                from: Data("""
                {"acknowledged":true,"createdOnDevice":false,"deadlineEpochSeconds":1791739200.0,"id":"t1","label":"eggs"}
                """.utf8)
            ),
            "acknowledged implies createdOnDevice; the wire cannot claim otherwise"
        )
    }

    func testCheckpointDecodeRejectsBadTimersAndNegativeStep() {
        let timer = """
        {"acknowledged":true,"createdOnDevice":false,"deadlineEpochSeconds":1791739200.0,"id":"t1","label":"eggs"}
        """
        let checkpoint = { (stepIndex: Int, timers: String) in
            Data("""
            {"completedStepIDs":[],"recipeRevision":{"revision":1,"source":"user","sourceRecipeID":"pancakes"},"sessionID":"s1","stepIndex":\(stepIndex),"timers":[\(timers)],"updatedAt":"2026-10-11T12:00:00.000Z"}
            """.utf8)
        }
        XCTAssertThrowsError(
            try decoder.decode(CookingSessionCheckpoint.self, from: checkpoint(0, timer)),
            "a checkpoint decoding must run the timer's own validation"
        )
        XCTAssertThrowsError(
            try decoder.decode(CookingSessionCheckpoint.self, from: checkpoint(-1, "{}"))
        )
        XCTAssertNoThrow(
            try decoder.decode(
                CookingSessionCheckpoint.self,
                from: checkpoint(0, #"{"acknowledged":true,"createdOnDevice":true,"deadlineEpochSeconds":1791739200.0,"id":"t1","label":"eggs"}"#
                )
            )
        )
    }

    // MARK: - Snapshot decode-time validation

    func testSnapshotDecodeRejectsInvalidRevisionAndStepIndex() {
        let snapshot = { (revision: Int, stepIndex: Int?) in
            Data("""
            {"capturedAt":"2026-10-11T12:00:00.000Z","pantrySummary":[],"recipeContext":null,"revision":\(revision),"sessionID":"s1","stepIndex":\(stepIndex.map(String.init) ?? "null")}
            """.utf8)
        }
        XCTAssertThrowsError(try decoder.decode(AssistantContextSnapshot.self, from: snapshot(0, nil)))
        XCTAssertThrowsError(try decoder.decode(AssistantContextSnapshot.self, from: snapshot(1, -2)))
        XCTAssertNoThrow(try decoder.decode(AssistantContextSnapshot.self, from: snapshot(1, nil)))
    }

    func testSnapshotRoundTripUsesISOTimestampsAndKeepsUnknownEvidence() throws {
        let snapshot = try AssistantContextSnapshot(
            sessionID: "s1", revision: 7,
            capturedAt: FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test"),
            pantrySummary: [
                try AssistantContextSnapshot.PantrySummaryLine(
                    canonicalName: "flour",
                    quantity: .unknown,
                    lastConfirmedAt: FLTimestamp.decode("2026-10-10T09:30:00.000Z", target: "test")
                )
            ]
        )
        let raw = String(decoding: try FLJSON.canonicalData(snapshot), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"capturedAt\" : \"2026-10-11T12:00:00.000Z\""), "got: \(raw)")
        XCTAssertTrue(raw.contains("\"lastConfirmedAt\" : \"2026-10-10T09:30:00.000Z\""), "got: \(raw)")
        XCTAssertFalse(raw.contains("813412800"), "no bare reference-epoch numbers may appear; got: \(raw)")
        let decoded = try decoder.decode(AssistantContextSnapshot.self, from: FLJSON.canonicalData(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.pantrySummary[0].quantity.isUnknown)
    }

    func testSnapshotDecodeRejectsNumericCapturedAt() {
        XCTAssertThrowsError(
            try decoder.decode(
                AssistantContextSnapshot.self,
                from: Data("""
                {"capturedAt":813412800,"pantrySummary":[],"recipeContext":null,"revision":1,"sessionID":"s1","stepIndex":null}
                """.utf8)
            )
        )
    }
}
