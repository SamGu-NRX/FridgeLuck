import XCTest
@testable import CookingSession

final class CookingSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("csc-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func fingerprint(
        stepTexts: [String],
        ingredientLines: [String] = ["2 cups rice", "1 tsp salt"],
        title: String = "Rice",
        recipeID: String = "recipe-rice"
    ) -> RecipeFingerprint {
        .compute(recipeID: recipeID, title: title, ingredientLines: ingredientLines, stepTexts: stepTexts)
    }

    private func identity(
        mode: CookingMode = .real,
        planID: String? = "plan-77",
        fingerprint: RecipeFingerprint
    ) -> CookingSessionIdentity {
        CookingSessionIdentity(
            mode: mode,
            planID: planID,
            fingerprint: fingerprint,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func activeCheckpoint(_ identity: CookingSessionIdentity, steps: [Int] = []) -> CookingCheckpoint {
        var checkpoint = CookingCheckpoint(identity: identity)
        for s in steps { checkpoint.progress.toggleStep(s) }
        return checkpoint
    }

    // MARK: Fingerprints

    func testFingerprintIsDeterministicAndSensitiveToInstructionChanges() throws {
        let steps = ["Rinse the rice", "Boil water", "Simmer 12 minutes"]
        let a = fingerprint(stepTexts: steps)
        let b = fingerprint(stepTexts: steps)
        XCTAssertEqual(a, b, "same recipe text must produce identical fingerprints")

        let reworded = fingerprint(stepTexts: ["Rinse the rice well", "Boil water", "Simmer 12 minutes"])
        XCTAssertNotEqual(a.instructionFingerprint, reworded.instructionFingerprint, "reworded instructions must change the fingerprint")

        let extraStep = fingerprint(stepTexts: steps + ["Fluff and serve"])
        XCTAssertNotEqual(a.instructionFingerprint, extraStep.instructionFingerprint)
        XCTAssertEqual(a.recipeFingerprint, extraStep.recipeFingerprint, "instruction-only changes must not move the recipe fingerprint")
    }

    func testFingerprintTracksRecipeIdentityAndIngredients() throws {
        let steps = ["Rinse the rice", "Boil water"]
        let a = fingerprint(stepTexts: steps)
        let otherRecipe = fingerprint(stepTexts: steps, recipeID: "recipe-quinoa", title: "Quinoa")
        XCTAssertNotEqual(a.recipeFingerprint, otherRecipe.recipeFingerprint)

        let changedIngredients = fingerprint(stepTexts: steps, ingredientLines: ["2 cups rice", "2 tsp salt"])
        XCTAssertNotEqual(a.recipeFingerprint, changedIngredients.recipeFingerprint)
        XCTAssertEqual(a.instructionFingerprint, changedIngredients.instructionFingerprint)
    }

    // MARK: Save / load round trip

    func testCheckpointSaveLoadRepeatReadsAreIdempotent() throws {
        let store = CookingSessionStore(directory: dir)
        let id = identity(fingerprint: fingerprint(stepTexts: ["Rinse", "Boil"]))
        let original = activeCheckpoint(id, steps: [0, 1])
        original.progress.substitutions["ingredient-butter"] = "ingredient-olive-oil"
        original.progress.checklist["mise-en-place"] = true

        try store.save(original)
        let first = try store.load(sessionID: id.sessionID)
        let second = try store.load(sessionID: id.sessionID)
        XCTAssertEqual(first, second, "repeat reads of unchanged bytes must be identical")
        XCTAssertEqual(first.progress.completedSteps, [0, 1])

        // Re-saving an unchanged checkpoint then reading again stays stable.
        try store.save(try store.load(sessionID: id.sessionID))
        XCTAssertEqual(try store.load(sessionID: id.sessionID), first)
    }

    func testCorruptFileReadsThrowInsteadOfCrashing() throws {
        let store = CookingSessionStore(directory: dir)
        let id = identity(mode: .practice, planID: nil, fingerprint: fingerprint(stepTexts: ["Knead", "Rest"]))
        try store.save(activeCheckpoint(id))

        let url = dir.appendingPathComponent("cooking-session-\(id.sessionID.uuidString).json")
        try Data("this is not json {".utf8).write(to: url)

        XCTAssertThrowsError(try store.load(sessionID: id.sessionID)) { error in
            guard case CheckpointStoreError.corrupt = error as! CheckpointStoreError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
        // Listing survives corrupt files.
        XCTAssertEqual(store.resumableSessions().count, 0)
    }

    func testTamperedPayloadFailsChecksum() throws {
        let store = CookingSessionStore(directory: dir)
        let id = identity(fingerprint: fingerprint(stepTexts: ["Rinse", "Boil"]))
        try store.save(activeCheckpoint(id, steps: [0]))

        let url = dir.appendingPathComponent("cooking-session-\(id.sessionID.uuidString).json")
        let decoder = JSONDecoder()
        var envelope = try decoder.decode(CheckpointEnvelope.self, from: try Data(contentsOf: url))
        // Rewrite the payload with different progress but keep the old checksum.
        let payloadDecoder = JSONDecoder()
        payloadDecoder.dateDecodingStrategy = .secondsSince1970
        var checkpoint = try payloadDecoder.decode(CookingCheckpoint.self, from: envelope.payload)
        checkpoint.progress.toggleStep(1)
        let payloadEncoder = JSONEncoder()
        payloadEncoder.dateEncodingStrategy = .secondsSince1970
        payloadEncoder.outputFormatting = [.sortedKeys]
        envelope.payload = try payloadEncoder.encode(checkpoint)
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.outputFormatting = [.sortedKeys]
        try envelopeEncoder.encode(envelope).write(to: url)

        XCTAssertThrowsError(try store.load(sessionID: id.sessionID)) { error in
            XCTAssertEqual(error as? CheckpointStoreError, .checksumMismatch)
        }
    }

    // MARK: State transitions

    func testActiveToCompletedAndAbandonedTransitions() throws {
        let store = CookingSessionStore(directory: dir)
        let finishID = identity(fingerprint: fingerprint(stepTexts: ["Rinse", "Boil"]))
        let abandonID = identity(fingerprint: fingerprint(stepTexts: ["Chop", "Sauté"]))

        try store.save(activeCheckpoint(finishID, steps: [0, 1]))
        try store.save(activeCheckpoint(abandonID, steps: [0]))

        // Real completion with a receipt.
        var finished = try store.load(sessionID: finishID.sessionID)
        finished.completionPending = false
        finished.phase = .completed
        finished.receipt = AcceptanceReceipt(
            receiptID: "rcpt-1",
            planID: finishID.planID ?? "",
            sessionID: finishID.sessionID,
            loggedAt: Date(timeIntervalSince1970: 1_780_000_100)
        )
        try store.save(finished)

        // Explicit abandon.
        var abandoned = try store.load(sessionID: abandonID.sessionID)
        abandoned.phase = .abandoned
        try store.save(abandoned)

        let resumable = store.resumableSessions()
        XCTAssertEqual(resumable, [], "completed and abandoned sessions are not resumable")

        let storedFinish = try store.load(sessionID: finishID.sessionID)
        XCTAssertEqual(storedFinish.phase, .completed)
        XCTAssertEqual(storedFinish.receipt?.receiptID, "rcpt-1")
        XCTAssertEqual(try store.load(sessionID: abandonID.sessionID).phase, .abandoned)
    }

    func testPracticeSessionCarriesNoPlanAndNoReceipt() throws {
        let store = CookingSessionStore(directory: dir)
        let practiceID = identity(mode: .practice, planID: nil, fingerprint: fingerprint(stepTexts: ["Whisk", "Fold"]))
        XCTAssertNil(practiceID.planID)

        var finished = activeCheckpoint(practiceID, steps: [0, 1])
        finished.phase = .completed
        finished.completionPending = false
        // Practice completion stores no receipt — nothing was logged.
        try store.save(finished)

        let stored = try store.load(sessionID: practiceID.sessionID)
        XCTAssertEqual(stored.identity.mode, .practice)
        XCTAssertNil(stored.receipt)
        XCTAssertFalse(stored.completionPending)
        XCTAssertEqual(stored.phase, .completed)
    }

    // MARK: Reconciliation

    func testStaleRecipeRequiresDeliberateReconciliation() throws {
        let stored = fingerprint(stepTexts: ["Rinse the rice", "Boil water", "Simmer 12 minutes"])

        // Same text now: compatible.
        XCTAssertEqual(stored.compare(to: stored), .compatible)

        // Reworded instructions now: indices must not be applied silently.
        let reworded = fingerprint(stepTexts: ["Rinse the rice", "Bring water to a boil", "Simmer 12 minutes"])
        XCTAssertEqual(stored.compare(to: reworded), .instructionsChanged)

        // Changed recipe (ingredient swap): full reconciliation.
        let newIngredients = fingerprint(stepTexts: ["Rinse the rice", "Boil water", "Simmer 12 minutes"], ingredientLines: ["2 cups rice", "1 pinch salt"])
        XCTAssertEqual(stored.compare(to: newIngredients), .recipeChanged)

        // Different recipe entirely.
        let other = fingerprint(stepTexts: ["Preheat oven"], recipeID: "recipe-cake", title: "Cake")
        XCTAssertEqual(stored.compare(to: other), .recipeChanged)
    }

    func testUnchangedRecipeResumesSameIndices() throws {
        let store = CookingSessionStore(directory: dir)
        let fp = fingerprint(stepTexts: ["Rinse", "Boil", "Simmer"])
        let id = identity(fingerprint: fp)
        try store.save(activeCheckpoint(id, steps: [0, 1]))

        // Relaunch: same recipe text, new store instance over the same files.
        let relaunchedStore = CookingSessionStore(directory: dir)
        let resumed = try relaunchedStore.load(sessionID: id.sessionID)
        XCTAssertEqual(resumed.identity.fingerprint.compare(to: fp), .compatible)
        XCTAssertEqual(resumed.progress.completedSteps, [0, 1])
        XCTAssertEqual(resumed.phase, .active)
        XCTAssertTrue(resumableContains(store: relaunchedStore, sessionID: id.sessionID))
    }

    private func resumableContains(store: CookingSessionStore, sessionID: UUID) -> Bool {
        store.resumableSessions().contains { $0.identity.sessionID == sessionID }
    }
}
