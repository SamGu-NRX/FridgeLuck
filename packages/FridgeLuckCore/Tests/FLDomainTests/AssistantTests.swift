import XCTest
@testable import FLDomain

final class AssistantTests: XCTestCase {
    private let t0 = try! FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")
    private let t1 = try! FLTimestamp.decode("2026-10-11T12:30:00.000Z", target: "test")
    private let validHash = String(repeating: "a", count: 64)
    private let revision = try! RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)

    private func makeCook() throws -> Cook {
        try Cook(id: "c1", recipeRevision: revision, servings: 2, rating: 4, completedAt: t0)
    }

    // MARK: Snapshot

    func testSnapshotValidation() throws {
        XCTAssertThrowsError(
            try AssistantContextSnapshot(sessionID: "  ", revision: 1, capturedAt: t0, pantrySummary: [])
        )
        XCTAssertThrowsError(
            try AssistantContextSnapshot(sessionID: "s1", revision: 0, capturedAt: t0, pantrySummary: [])
        )
        XCTAssertThrowsError(
            try AssistantContextSnapshot(sessionID: "s1", revision: 1, capturedAt: t0, pantrySummary: [], stepIndex: -1)
        )
        XCTAssertNoThrow(
            try AssistantContextSnapshot(sessionID: "s1", revision: 1, capturedAt: t0, pantrySummary: [])
        )
    }

    func testSnapshotRoundTripWithUnknownQuantities() throws {
        let snapshot = try AssistantContextSnapshot(
            sessionID: "s1", revision: 7,
            capturedAt: t0,
            pantrySummary: [
                .init(
                    canonicalName: "flour",
                    quantity: .unknown,
                    lastConfirmedAt: try FLTimestamp.decode("2026-10-10T09:30:00.000Z", target: "test")
                )
            ],
            recipeContext: revision,
            stepIndex: 2
        )
        let decoded = try FLJSON.canonicalDecoder().decode(AssistantContextSnapshot.self, from: FLJSON.canonicalData(snapshot))
        XCTAssertEqual(decoded, snapshot)
        // Unknown quantity evidence reaches the model as unknown, never as a number.
        XCTAssertTrue(decoded.pantrySummary[0].quantity.isUnknown)
    }

    // MARK: Payload

    func testPayloadDecodesAllVariants() throws {
        let decoder = FLJSON.canonicalDecoder()
        XCTAssertEqual(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"stepAdvance","stepIndex":2}"#.utf8)),
            .stepAdvance(stepIndex: 2)
        )
        XCTAssertEqual(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"timerCreate","label":"eggs","seconds":600}"#.utf8)),
            .timerCreate(label: "eggs", seconds: 600)
        )
        let decoded = try decoder.decode(
            ActionPayload.self,
            from: Data(#"{"kind":"pantryCorrection","canonicalName":"flour","quantity":{"kind":"unknown"}}"#.utf8)
        )
        guard case let .pantryCorrection(name, quantity) = decoded else {
            return XCTFail("expected pantryCorrection, got \(decoded)")
        }
        XCTAssertEqual(name, "flour")
        XCTAssertTrue(quantity.isUnknown)

        let logged = try decoder.decode(ActionPayload.self, from: FLJSON.canonicalData(ActionPayload.mealLog(cook: makeCook())))
        guard case .mealLog(let cook) = logged else {
            return XCTFail("expected mealLog, got \(logged)")
        }
        XCTAssertEqual(cook.servings, 2)
    }

    func testPayloadRejectsBadVariants() {
        let decoder = FLJSON.canonicalDecoder()
        // Negative step index.
        XCTAssertThrowsError(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"stepAdvance","stepIndex":-1}"#.utf8))
        )
        // Zero-length timer.
        XCTAssertThrowsError(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"timerCreate","label":"eggs","seconds":0}"#.utf8))
        )
        // Blank timer label.
        XCTAssertThrowsError(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"timerCreate","label":"  ","seconds":60}"#.utf8))
        )
        // Unknown payload kind never decodes to "something reasonable".
        XCTAssertThrowsError(
            try decoder.decode(ActionPayload.self, from: Data(#"{"kind":"runShellCommand"}"#.utf8))
        )
    }

    // MARK: Proposal / approval binding

    func testProposalRejectsBadHash() throws {
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .proposeMealLog, payload: .mealLog(cook: makeCook()),
                payloadHash: String(repeating: "A", count: 64), snapshotRevision: 3, createdAt: t0
            )
        ) // uppercase hex
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .proposeMealLog, payload: .mealLog(cook: makeCook()),
                payloadHash: "abc", snapshotRevision: 3, createdAt: t0
            )
        ) // wrong length
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .proposeMealLog, payload: .mealLog(cook: makeCook()),
                payloadHash: validHash, snapshotRevision: 0, createdAt: t0
            )
        ) // revision must be >= 1
    }

    func testProposalExpiresAtMustFollowCreatedAt() throws {
        XCTAssertThrowsError(
            try ActionProposal(
                id: "p1", tool: .proposeStepAdvance, payload: .stepAdvance(stepIndex: 1),
                payloadHash: validHash, snapshotRevision: 3, createdAt: t1, expiresAt: t0
            )
        )
        XCTAssertNoThrow(
            try ActionProposal(
                id: "p1", tool: .proposeStepAdvance, payload: .stepAdvance(stepIndex: 1),
                payloadHash: validHash, snapshotRevision: 3, createdAt: t0, expiresAt: t1
            )
        )
    }

    func testApprovalFormatValidation() throws {
        XCTAssertNoThrow(try ActionApproval(proposalID: "p1", payloadHash: validHash, snapshotRevision: 3, approvedAt: t0))
        XCTAssertThrowsError(
            try ActionApproval(proposalID: "p1", payloadHash: String(repeating: "z", count: 63), snapshotRevision: 3, approvedAt: t0)
        )
        XCTAssertThrowsError(
            try ActionApproval(proposalID: "p1", payloadHash: validHash, snapshotRevision: 0, approvedAt: t0)
        )
        XCTAssertThrowsError(
            try ActionApproval(proposalID: "  ", payloadHash: validHash, snapshotRevision: 3, approvedAt: t0)
        )
    }

    // MARK: Receipts

    func testReceiptRoundTrip() throws {
        let receipt = try ActionReceipt(
            proposalID: "p1", state: .executed, payloadHash: validHash,
            snapshotRevision: 3, recordedAt: t0
        )
        let decoded = try FLJSON.canonicalDecoder().decode(ActionReceipt.self, from: FLJSON.canonicalData(receipt))
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.state, .executed)
    }

    func testReceiptAllowsUnboundFieldsAndRejectsBadHash() throws {
        // A pendingApproval receipt exists before a payload hash is bound.
        XCTAssertNoThrow(try ActionReceipt(proposalID: "p1", state: .pendingApproval, payloadHash: nil, snapshotRevision: nil, recordedAt: t0))
        XCTAssertThrowsError(
            try ActionReceipt(proposalID: "p1", state: .executed, payloadHash: "not-a-hash", snapshotRevision: 1, recordedAt: t0)
        )
        XCTAssertThrowsError(
            try ActionReceipt(proposalID: "p1", state: .executed, payloadHash: nil, snapshotRevision: 0, recordedAt: t0)
        )
    }

    // MARK: Cooking session checkpoint

    func testTimerAcknowledgmentRequiresDeviceCreation() throws {
        XCTAssertNoThrow(
            try CookingSessionCheckpoint.TimerRecord(
                id: "t1", label: "eggs", deadlineEpochSeconds: 1_792_000_000,
                createdOnDevice: false, acknowledged: false
            )
        )
        // A proposal-side timer (not created on device) can never be acknowledged.
        XCTAssertThrowsError(
            try CookingSessionCheckpoint.TimerRecord(
                id: "t2", label: "eggs", deadlineEpochSeconds: 1_792_000_000,
                createdOnDevice: false, acknowledged: true
            )
        )
        XCTAssertThrowsError(
            try CookingSessionCheckpoint.TimerRecord(
                id: "t3", label: "eggs", deadlineEpochSeconds: .infinity,
                createdOnDevice: true, acknowledged: true
            )
        )
    }

    func testCheckpointRejectsDuplicateCompletedSteps() throws {
        XCTAssertThrowsError(
            try CookingSessionCheckpoint(
                sessionID: "s1", recipeRevision: revision, stepIndex: 2,
                completedStepIDs: ["a", "a", "b"], timers: [], updatedAt: t0
            )
        )
        XCTAssertThrowsError(
            try CookingSessionCheckpoint(
                sessionID: "s1", recipeRevision: revision, stepIndex: 2,
                completedStepIDs: ["a", "  "], timers: [], updatedAt: t0
            )
        )
        XCTAssertNoThrow(
            try CookingSessionCheckpoint(
                sessionID: "s1", recipeRevision: revision, stepIndex: 2,
                completedStepIDs: ["a", "b"], timers: [], updatedAt: t0
            )
        )
    }

    func testCheckpointRoundTrip() throws {
        let checkpoint = try CookingSessionCheckpoint(
            sessionID: "s1", recipeRevision: revision, stepIndex: 1,
            completedStepIDs: ["step-0"],
            timers: [
                try CookingSessionCheckpoint.TimerRecord(
                    id: "t1", label: "eggs", deadlineEpochSeconds: 1_792_000_000,
                    createdOnDevice: true, acknowledged: true
                )
            ],
            updatedAt: t0
        )
        let decoded = try FLJSON.canonicalDecoder().decode(CookingSessionCheckpoint.self, from: FLJSON.canonicalData(checkpoint))
        XCTAssertEqual(decoded, checkpoint)
    }
}
