import XCTest
@testable import FLDomain

// MARK: - Review round 2, item 2: share-card decoding obeys the same rules
// as construction
//
// SPEC 3.4: the shareable card carries the DAY — never exact times. The
// validated init enforces "YYYY-MM-DD", but the synthesized decode bypassed
// it, so a received share could carry an exact timestamp in `day` (plus
// zero servings, out-of-range ratings, multiline notes and empty swap names).
// The red-first outputs below were recorded against pre-fix code.

final class ShareCardDecodeValidationTests: XCTestCase {
    // A card payload with every other field valid, so a thrown error can only
    // be about the one value under test.
    private func cardData(
        day: String = "2026-10-11",
        servings: Int = 2,
        swaps: String = "[]",
        rating: Int = 4,
        note: String? = nil
    ) throws -> Data {
        let revision = try RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 2)
        let revisionJSON = String(
            decoding: try FLJSON.canonicalData(revision),
            as: UTF8.self
        )
        let noteJSON = note.map { "\($0.debugDescription)" } ?? "null"
        return Data("""
        {
          "recipeRevision": \(revisionJSON),
          "day": "\(day)",
          "servings": \(servings),
          "swaps": \(swaps),
          "rating": \(rating),
          "note": \(noteJSON)
        }
        """.utf8)
    }

    private func decode(_ data: Data) throws -> CookShareCard {
        try FLJSON.canonicalDecoder().decode(CookShareCard.self, from: data)
    }

    func testDecodeRejectsExactTimestampInDay() throws {
        let exactTimestamp = "2026-10-12T18:44:56.250Z"
        XCTAssertThrowsError(try decode(try cardData(day: exactTimestamp)), "an exact timestamp is not a day") { error in
            XCTAssertEqual(
                error as? FLDomainError,
                FLDomainError.validation(
                    target: "CookShareCard.day",
                    reason: "must be a UTC calendar day \"YYYY-MM-DD\" (got \(exactTimestamp))"
                )
            )
        }
    }

    func testDecodeRejectsTimestampWithoutFractionalSecondsInDay() throws {
        XCTAssertThrowsError(try decode(try cardData(day: "2026-10-12T18:44:56Z")))
        XCTAssertThrowsError(try decode(try cardData(day: "2026-10-12 18:44")))
        XCTAssertThrowsError(try decode(try cardData(day: "2026-10-12T18:44")))
    }

    func testDecodeRejectsShapeValidButImpossibleCalendarDays() throws {
        // Review round 2, lesser finding: the shape check alone let
        // "2026-99-99" through. A day must survive the UTC calendar.
        XCTAssertThrowsError(try decode(try cardData(day: "2026-99-99")), "month 99 is not a calendar month")
        XCTAssertThrowsError(try decode(try cardData(day: "2026-02-30")), "February 30 does not exist")
        XCTAssertThrowsError(try decode(try cardData(day: "2025-02-29")), "2025 is not a leap year")
        XCTAssertThrowsError(try decode(try cardData(day: "2026-00-10")), "month zero is not a calendar month")
        XCTAssertThrowsError(try decode(try cardData(day: "2026-13-01")), "month thirteen is not a calendar month")
    }

    func testDecodeAcceptsLeapDayAndPlainCalendarDay() throws {
        // The calendar check must not over-reject: a real leap day decodes.
        XCTAssertEqual(try decode(try cardData(day: "2024-02-29")).day, "2024-02-29")
        XCTAssertEqual(try decode(try cardData(day: "2026-10-11")).day, "2026-10-11")
    }

    func testDecodeRejectsZeroServings() throws {
        XCTAssertThrowsError(try decode(try cardData(servings: 0))) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "CookShareCard.servings", reason: "must be >= 1 (got 0)"))
        }
    }

    func testDecodeRejectsOutOfRangeRating() throws {
        XCTAssertThrowsError(try decode(try cardData(rating: 6))) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "CookShareCard.rating", reason: "must be in 1...5 (got 6)"))
        }
        XCTAssertThrowsError(try decode(try cardData(rating: 0)))
    }

    func testDecodeRejectsMultilineNote() throws {
        XCTAssertThrowsError(try decode(try cardData(note: "line one\nline two"))) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "CookShareCard.note", reason: "note is one line; newlines are not allowed"))
        }
    }

    func testDecodeRejectsSwapWithBlankName() throws {
        let swaps = #"[{"fromName":"onion","toName":"   ","necessity":"preferred"}]"#
        XCTAssertThrowsError(try decode(try cardData(swaps: swaps)), "a decoded swap must not carry blank names") { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "CookShareSwap", reason: "swap names must not be empty"))
        }
    }

    func testDecodeAcceptsAValidCardAndRoundTrips() throws {
        let swaps = #"[{"fromName":"onion","toName":"shallot","necessity":"necessary"}]"#
        let data = try cardData(swaps: swaps, note: "extra crispy")
        let decoded = try decode(data)
        XCTAssertEqual(decoded.day, "2026-10-11")
        XCTAssertEqual(decoded.servings, 2)
        XCTAssertEqual(decoded.rating, 4)
        XCTAssertEqual(decoded.note, "extra crispy")
        XCTAssertEqual(decoded.swaps.count, 1)
        XCTAssertEqual(decoded.swaps.first?.toName, "shallot")

        let reencoded = try FLJSON.canonicalEncoder().encode(decoded)
        XCTAssertEqual(try decode(reencoded), decoded, "encode then decode must round-trip")
    }

    func testEncodedCardFromAValidCookCarriesNoExactTimes() throws {
        let cook = try Cook(
            id: "cook-1",
            recipeRevision: RecipeKey(source: .catalog, sourceRecipeID: "soup", revision: 7),
            servings: 2,
            substitutions: [
                try CookSubstitution(
                    from: IngredientReference(canonicalName: "onion"),
                    to: IngredientReference(canonicalName: "shallot"),
                    necessity: .necessary
                )
            ],
            rating: 3,
            note: nil,
            startedAt: try FLTimestamp.decode("2026-10-11T18:02:03.500Z", target: "test"),
            completedAt: try FLTimestamp.decode("2026-10-11T18:44:56.250Z", target: "test")
        )
        let card = try CookShareCard(cook: cook)
        let payload = String(decoding: try FLJSON.canonicalData(card), as: UTF8.self)

        XCTAssertFalse(payload.contains("T18:44:56"), "no exact finish time may travel")
        XCTAssertFalse(payload.contains("18:02:03"), "no exact start time may travel")
        XCTAssertTrue(payload.contains("2026-10-11"), "the UTC day travels")
    }
}

// MARK: - Review round 2, item 3: constructed payloads obey the same value
// rules as decoded payloads
//
// ActionPayload.init(from:) validated stepAdvance/timerCreate inline, but a
// payload built in code had no gate at all — and neither did
// ActionProposal.init, which only checks tool/payload agreement — and
// pantryCorrection was unchecked on both paths. One validation rule for
// every payload, no separate fast path.

final class ConstructedPayloadValidationTests: XCTestCase {
    private let hash64 = String(repeating: "a", count: 64)
    private let now = Date()

    private func makeProposal(tool: AssistantTool, payload: ActionPayload) throws -> ActionProposal {
        try ActionProposal(
            id: "prop-1",
            tool: tool,
            payload: payload,
            payloadHash: hash64,
            snapshotRevision: 1,
            createdAt: now
        )
    }

    func testProposalRejectsConstructedTimerWithBlankLabel() {
        XCTAssertThrowsError(
            try makeProposal(tool: .proposeTimer, payload: .timerCreate(label: "   ", seconds: 30))
        ) { error in
            XCTAssertEqual(
                error as? FLDomainError,
                FLDomainError.validation(target: "ActionPayload.timerCreate.label", reason: "must not be empty")
            )
        }
    }

    func testProposalRejectsConstructedTimerWithZeroSeconds() {
        XCTAssertThrowsError(
            try makeProposal(tool: .proposeTimer, payload: .timerCreate(label: "Tea", seconds: 0))
        ) { error in
            XCTAssertEqual(
                error as? FLDomainError,
                FLDomainError.validation(target: "ActionPayload.timerCreate.seconds", reason: "must be > 0 (got 0)")
            )
        }
        XCTAssertThrowsError(try makeProposal(tool: .proposeTimer, payload: .timerCreate(label: "Tea", seconds: -5)))
    }

    func testProposalRejectsConstructedNegativeStepIndex() {
        XCTAssertThrowsError(
            try makeProposal(tool: .proposeStepAdvance, payload: .stepAdvance(stepIndex: -1))
        ) { error in
            XCTAssertEqual(
                error as? FLDomainError,
                FLDomainError.validation(target: "ActionPayload.stepAdvance.stepIndex", reason: "must be >= 0 (got -1)")
            )
        }
    }

    func testProposalRejectsConstructedPantryCorrectionWithBlankName() {
        XCTAssertThrowsError(
            try makeProposal(tool: .proposePantryCorrection, payload: .pantryCorrection(canonicalName: "   ", quantity: .unknown))
        ) { error in
            XCTAssertEqual(
                error as? FLDomainError,
                FLDomainError.validation(target: "ActionPayload.pantryCorrection.canonicalName", reason: "must not be empty")
            )
        }
    }

    func testValidConstructedTimerStillProducesAProposalAndRoundTrips() throws {
        let proposal = try makeProposal(tool: .proposeTimer, payload: .timerCreate(label: "Tea", seconds: 180))
        XCTAssertEqual(proposal.tool, .proposeTimer)
        guard case .timerCreate(let label, let seconds) = proposal.payload else {
            return XCTFail("the payload must survive construction")
        }
        XCTAssertEqual(label, "Tea")
        XCTAssertEqual(seconds, 180)
        // The name says round-trips: prove the constructed payload survives
        // the canonical wire boundary, not just pattern matching.
        let wire = try FLJSON.canonicalEncoder().encode(proposal.payload)
        let decoded = try FLJSON.canonicalDecoder().decode(ActionPayload.self, from: wire)
        XCTAssertEqual(decoded, proposal.payload)
    }

    func testDecodedPayloadsKeepTheirExistingValidation() throws {
        // Regression guard: the decode path already rejected these (round 1);
        // the shared rule must not weaken them. Error targets are frozen — a
        // receipt or backend may match on them.
        func decodePayload(_ json: String) throws -> ActionPayload {
            try FLJSON.canonicalDecoder().decode(ActionPayload.self, from: Data(json.utf8))
        }
        XCTAssertThrowsError(try decodePayload(#"{"kind":"stepAdvance","stepIndex":-1}"#)) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "ActionPayload.stepAdvance.stepIndex", reason: "must be >= 0 (got -1)"))
        }
        XCTAssertThrowsError(try decodePayload(#"{"kind":"timerCreate","label":"  ","seconds":10}"#)) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "ActionPayload.timerCreate.label", reason: "must not be empty"))
        }
        XCTAssertThrowsError(try decodePayload(#"{"kind":"timerCreate","label":"Tea","seconds":0}"#)) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "ActionPayload.timerCreate.seconds", reason: "must be > 0 (got 0)"))
        }
        // The previously UNCHECKED decode case: a blank canonical name must
        // now be refused exactly like a constructed one.
        XCTAssertThrowsError(try decodePayload(#"{"kind":"pantryCorrection","canonicalName":"   ","quantity":{"kind":"unknown"}}"#)) { error in
            XCTAssertEqual(error as? FLDomainError, FLDomainError.validation(target: "ActionPayload.pantryCorrection.canonicalName", reason: "must not be empty"))
        }
    }
}
