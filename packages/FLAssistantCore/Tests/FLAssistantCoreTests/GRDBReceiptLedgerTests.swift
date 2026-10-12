import XCTest
@testable import FLAssistantCore
import FLDomain
import FLPersistence
import GRDB

/// The M3 durable-ledger suite: versioned migration composed on the FLPersistence
/// baseline, receipt round-trips through the domain's throwing initializer,
/// restart idempotency (a decided proposal refuses across process lifetimes),
/// and atomic effects-plus-receipt execution with full rollback.
final class GRDBReceiptLedgerTests: XCTestCase {
    private let t0 = try! FLTimestamp.decode("2026-10-11T12:00:00.000Z", target: "test")

    // MARK: Helpers

    private func expectError(
        _ expected: FLAssistantError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected refusal: \(expected)", file: file, line: line)
        } catch let error as FLAssistantError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    private func makeSnapshot(revision: Int = 1, sessionID: String = "s1") throws -> AssistantContextSnapshot {
        try AssistantContextSnapshot(
            sessionID: sessionID,
            revision: revision,
            capturedAt: t0,
            pantrySummary: [],
            recipeContext: nil,
            stepIndex: 0
        )
    }

    private func makeApproval(for proposal: ActionProposal) throws -> ActionApproval {
        try ActionApproval(
            proposalID: proposal.id,
            payloadHash: proposal.payloadHash,
            snapshotRevision: proposal.snapshotRevision,
            approvedAt: t0
        )
    }

    private func makeAuthority(ledger: any ReceiptLedger, id: String) throws -> AssistantAuthority {
        try AssistantAuthority(
            engine: ActionProposalEngine(idSource: { id }),
            ledger: ledger,
            revisionClock: AssistantRevisionClock(revision: 1)
        )
    }

    private func tempDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fl-assistant-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// An executor whose effect is one row in `fl_test_effects`; can be told
    /// to throw after writing, to prove the rollback covers both sides.
    private struct InsertExecutor: GRDBActionExecutor {
        var shouldThrow: Bool = false

        func apply(_ payload: ActionPayload, proposal: ActionProposal, in db: Database) throws {
            try db.execute(
                sql: "INSERT INTO fl_test_effects (proposalID) VALUES (?)",
                arguments: [proposal.id]
            )
            if shouldThrow {
                throw FLAssistantError.malformedReply(detail: "executor failure injected by test")
            }
        }
    }

    /// A ledger over an in-memory database with the test effects table present.
    private func makeLedger() throws -> GRDBReceiptLedger {
        let ledger = try GRDBReceiptLedger.inMemory()
        try ledger.database.write { db in
            try db.execute(sql: "CREATE TABLE fl_test_effects (proposalID TEXT NOT NULL)")
        }
        return ledger
    }

    private func effectCount(_ ledger: GRDBReceiptLedger) throws -> Int {
        try ledger.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fl_test_effects") ?? 0
        }
    }

    // MARK: Migration

    func testMigrationComposesBaselineAndReceiptTable() throws {
        let appDatabase = try AppDatabase.inMemory()
        XCTAssertFalse(try appDatabase.tableExists("fl_assistant_receipt"), "nothing before the ledger migrates")
        _ = try GRDBReceiptLedger(database: appDatabase)
        XCTAssertTrue(try appDatabase.tableExists("fl_schema_baseline"), "Part 1's baseline ran first")
        XCTAssertTrue(try appDatabase.tableExists("fl_assistant_receipt"), "the assistant table was appended")
    }

    func testMigrationRegistryRecordsAllThreeVersions() throws {
        let ledger = try GRDBReceiptLedger.inMemory()
        let applied = try ledger.database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(applied.contains("v1-baseline"))
        XCTAssertTrue(applied.contains("v2-assistant-receipts"))
        // Round 2, item 3: the durable exactly-once claim.
        XCTAssertTrue(applied.contains("v3-assistant-receipt-executed-once"))
    }

    // MARK: Receipt round-trips

    func testReceiptRoundTripAndLatestWins() async throws {
        let ledger = try GRDBReceiptLedger.inMemory()
        let hash = String(repeating: "ab", count: 32)
        try await ledger.record(try ActionReceipt(
            proposalID: "p-1", state: .pendingApproval,
            payloadHash: hash, snapshotRevision: 3, recordedAt: t0
        ))
        try await ledger.record(try ActionReceipt(
            proposalID: "p-1", state: .executed,
            payloadHash: hash, snapshotRevision: 3, recordedAt: t0.addingTimeInterval(5)
        ))
        let latest = try await ledger.latestReceipt(proposalID: "p-1")
        XCTAssertEqual(latest?.state, .executed)
        XCTAssertEqual(latest?.snapshotRevision, 3)
        let all = try await ledger.allReceipts()
        XCTAssertEqual(all.map(\.state), [.pendingApproval, .executed], "rows read back oldest first")
        let missing = try await ledger.latestReceipt(proposalID: "never-minted")
        XCTAssertNil(missing)
    }

    func testLatestReceiptSurvivesReopen() async throws {
        let url = tempDatabaseURL()
        defer { removeDatabase(url) }
        let hash = String(repeating: "cd", count: 32)
        let first = try GRDBReceiptLedger.open(at: url)
        try await first.record(try ActionReceipt(
            proposalID: "p-1", state: .pendingApproval,
            payloadHash: hash, snapshotRevision: 1, recordedAt: t0
        ))
        // A "restart": a brand-new ledger over the same file.
        let reopened = try GRDBReceiptLedger.open(at: url)
        let latest = try await reopened.latestReceipt(proposalID: "p-1")
        XCTAssertEqual(latest?.state, .pendingApproval)
        XCTAssertEqual(latest?.recordedAt, t0)
    }

    func testRecordedAtIsStoredAsISO8601Text() async throws {
        let ledger = try GRDBReceiptLedger.inMemory()
        let hash = String(repeating: "ef", count: 32)
        try await ledger.record(try ActionReceipt(
            proposalID: "p-1", state: .pendingApproval,
            payloadHash: hash, snapshotRevision: 1, recordedAt: t0
        ))
        let raw = try ledger.database.read { db in
            try String.fetchOne(db, sql: "SELECT recordedAt FROM fl_assistant_receipt")
        }
        let stored = try XCTUnwrap(raw)
        XCTAssertNil(Double(stored), "dates are contract-form ISO 8601 text, never numeric epochs")
        let decoded = try FLTimestamp.decode(stored, target: "test")
        XCTAssertEqual(decoded.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCorruptReceiptStateRefusesRead() async throws {
        let ledger = try GRDBReceiptLedger.inMemory()
        try ledger.database.write { db in
            try db.execute(sql: """
                INSERT INTO fl_assistant_receipt
                    (proposalID, state, payloadHash, snapshotRevision, recordedAt)
                VALUES ('p-x', 'smudged', NULL, NULL, '2026-10-11T12:00:00.000Z')
                """)
        }
        await expectError(.corruptLedgerRow(detail: "unknown receipt state 'smudged'")) {
            _ = try await ledger.latestReceipt(proposalID: "p-x")
        }
    }

    // MARK: Atomic execution

    func testAtomicApproveCommitsEffectsAndReceiptTogether() async throws {
        let ledger = try makeLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-atomic")
        let proposal = try await authority.propose(
            tool: .proposeTimer,
            payload: .timerCreate(label: "Boil water", seconds: 90),
            against: try makeSnapshot(),
            now: t0
        )
        let receipt = try await authority.approve(
            try makeApproval(for: proposal),
            executor: InsertExecutor(),
            sessionID: "s1",
            now: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(receipt.state, .executed)
        let latestAfter = try await ledger.latestReceipt(proposalID: proposal.id)
        XCTAssertEqual(latestAfter?.state, .executed)
        XCTAssertEqual(try effectCount(ledger), 1, "the effect row committed with the receipt")
    }

    func testAtomicApproveRollsBackEffectsAndReceiptWhenExecutorThrows() async throws {
        let ledger = try makeLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-rollback")
        let proposal = try await authority.propose(
            tool: .proposeTimer,
            payload: .timerCreate(label: "Boil water", seconds: 90),
            against: try makeSnapshot(),
            now: t0
        )
        await expectError(.malformedReply(detail: "executor failure injected by test")) {
            try await authority.approve(
                try self.makeApproval(for: proposal),
                executor: InsertExecutor(shouldThrow: true),
                sessionID: "s1",
                now: t0.addingTimeInterval(2)
            )
        }
        XCTAssertEqual(try effectCount(ledger), 0, "the effect write rolled back with the failed transaction")
        let receipts = try await ledger.allReceipts()
        XCTAssertEqual(receipts.map(\.state), [.pendingApproval], "no executed receipt for work that did not happen")
    }

    func testReplayAcrossRestartRefusesAlreadyDecided() async throws {
        let url = tempDatabaseURL()
        defer { removeDatabase(url) }
        // Process 1: propose and execute atomically.
        let first = try GRDBReceiptLedger.open(at: url)
        try first.database.write { db in
            try db.execute(sql: "CREATE TABLE fl_test_effects (proposalID TEXT NOT NULL)")
        }
        let authority1 = try makeAuthority(ledger: first, id: "proposal-restart")
        let proposal = try await authority1.propose(
            tool: .proposeStepAdvance,
            payload: .stepAdvance(stepIndex: 2),
            against: try makeSnapshot(),
            now: t0
        )
        let approval = try makeApproval(for: proposal)
        _ = try await authority1.approve(approval, executor: InsertExecutor(), sessionID: "s1", now: t0.addingTimeInterval(2))

        // Process 2: fresh authority over the same database, empty open set.
        let second = try GRDBReceiptLedger.open(at: url)
        try second.database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS fl_test_effects (proposalID TEXT NOT NULL)")
        }
        let authority2 = try makeAuthority(ledger: second, id: "proposal-restart")
        await expectError(.alreadyDecided(proposalID: "proposal-restart")) {
            try await authority2.approve(approval, executor: InsertExecutor(), sessionID: "s1", now: t0.addingTimeInterval(4))
        }
        let receipts = try await second.allReceipts()
        XCTAssertEqual(receipts.map(\.state), [.pendingApproval, .executed], "the earlier receipt stands; no duplicate row")
        XCTAssertEqual(try effectCount(second), 1, "the effects ran exactly once across both lifetimes")
    }

    func testAtomicApproveRefusesNonTransactionalLedger() async throws {
        let ledger = InMemoryReceiptLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-notx")
        let proposal = try await authority.propose(
            tool: .proposePantryCorrection,
            payload: .pantryCorrection(canonicalName: "Milk", quantity: .unknown),
            against: try makeSnapshot(),
            now: t0
        )
        await expectError(.ledgerCannotExecuteAtomically) {
            try await authority.approve(
                try makeApproval(for: proposal),
                executor: InsertExecutor(),
                sessionID: "s1",
                now: t0.addingTimeInterval(2)
            )
        }
        let receipts = try await ledger.allReceipts()
        XCTAssertEqual(receipts.map(\.state), [.pendingApproval], "nothing ran, nothing was consumed")
        // The proposal is still open: a decline (no executor needed) proves
        // it was not consumed by the refused approval.
        let declined = try await authority.decline(proposalID: proposal.id, now: t0.addingTimeInterval(3))
        XCTAssertEqual(declined.state, .rejected)
    }

    // MARK: Review round 2, item 4 — receipt failure after the effect rolls the effect back

    /// Thrown from the `betweenWrites` seam: occupies exactly the gap a
    /// receipt persistence failure occupies — after the effects, before the
    /// receipt insert, inside the open transaction.
    private static let seamFailure = FLAssistantError.malformedReply(
        detail: "seam failure injected by test"
    )

    /// The paired write's injected-failure test (mirrors the foundation's
    /// `writeCompletedCook` seam test): the effect writes, then the receipt
    /// half fails — and the EFFECT ROLLS BACK. A retry therefore cannot apply
    /// the effect a second time: nothing survived the failed attempt.
    func testInjectedFailureBetweenEffectAndReceiptPersistsNeither() async throws {
        let ledger = try makeLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-seam-fail")
        let proposal = try await authority.propose(
            tool: .proposeTimer,
            payload: .timerCreate(label: "Boil water", seconds: 90),
            against: try makeSnapshot(),
            now: t0
        )
        await expectError(.malformedReply(detail: "seam failure injected by test")) {
            _ = try await ledger.executeAndRecord(
                proposal: proposal,
                executor: InsertExecutor(),
                recordedAt: t0.addingTimeInterval(2),
                betweenWrites: { _ in throw Self.seamFailure }
            )
        }
        XCTAssertEqual(
            try effectCount(ledger), 0,
            "the effect rolled back with the receipt it was paired with"
        )
        let receipts = try await ledger.allReceipts()
        XCTAssertEqual(receipts.map(\.state), [.pendingApproval], "no executed receipt for work that did not happen")
        // The retry with a healthy path applies exactly once: nothing
        // survived the rolled-back attempt, so there is no double mutation.
        let receipt = try await authority.approve(
            try makeApproval(for: proposal),
            executor: InsertExecutor(),
            sessionID: "s1",
            now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(receipt.state, .executed)
        XCTAssertEqual(try effectCount(ledger), 1, "the retry applied the effect exactly once")
        let statesAfter = try await ledger.allReceipts().map(\.state)
        XCTAssertEqual(statesAfter, [.pendingApproval, .executed])
    }

    /// The seam's control: a non-throwing injection between the halves must
    /// not disturb the pairing — both writes persist.
    func testNonThrowingInjectionBetweenEffectAndReceiptPersistsBoth() async throws {
        let ledger = try makeLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-seam-ok")
        let proposal = try await authority.propose(
            tool: .proposeTimer,
            payload: .timerCreate(label: "Boil water", seconds: 90),
            against: try makeSnapshot(),
            now: t0
        )
        _ = try await ledger.executeAndRecord(
            proposal: proposal,
            executor: InsertExecutor(),
            recordedAt: t0.addingTimeInterval(2),
            betweenWrites: { db in
                try db.execute(
                    sql: "INSERT INTO fl_test_effects (proposalID) VALUES ('seam-witness')"
                )
            }
        )
        XCTAssertEqual(
            try effectCount(ledger), 2,
            "the executor's row and the seam's witness row both committed"
        )
        let states = try await ledger.allReceipts().map(\.state)
        XCTAssertEqual(states, [.pendingApproval, .executed])
    }

    // MARK: Review round 2, item 3 — exactly-once execution (durable half)

    /// RED-FIRST (round 2, item 3, durable half): a second atomic execution
    /// of the same proposal must refuse INSIDE the transaction — the first
    /// execution's receipt is already durable — and apply nothing. Against
    /// pre-fix code the second call re-applies the effect: this test failed
    /// with `2` effect rows where exactly-once demands `1`.
    func testSecondAtomicExecutionRefusesInsideTheTransactionAndAppliesNothing() async throws {
        let ledger = try makeLedger()
        let authority = try makeAuthority(ledger: ledger, id: "proposal-recheck")
        let proposal = try await authority.propose(
            tool: .proposeTimer,
            payload: .timerCreate(label: "Boil water", seconds: 90),
            against: try makeSnapshot(),
            now: t0
        )
        _ = try await ledger.executeAndRecord(
            proposal: proposal, executor: InsertExecutor(), recordedAt: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(try effectCount(ledger), 1)
        await expectError(.alreadyDecided(proposalID: proposal.id)) {
            _ = try await ledger.executeAndRecord(
                proposal: proposal, executor: InsertExecutor(), recordedAt: t0.addingTimeInterval(3)
            )
        }
        XCTAssertEqual(try effectCount(ledger), 1, "the refused second execution applied nothing")
        let receipts = try await ledger.allReceipts()
        XCTAssertEqual(receipts.map(\.state), [.pendingApproval, .executed], "no duplicate executed receipt")
    }

    /// RED-FIRST (round 2, item 3, storage half): the DURABLE claim backs the
    /// in-transaction recheck — a UNIQUE index refuses a second executed
    /// receipt per proposal against any code path that skips the recheck.
    /// Against pre-fix code the duplicate insert succeeded: this test failed
    /// on `XCTAssertThrowsError` before the index existed.
    func testDurableExecutedClaimIsUniquePerProposal() async throws {
        let ledger = try GRDBReceiptLedger.inMemory()
        let hash = String(repeating: "ab", count: 32)
        try await ledger.record(try ActionReceipt(
            proposalID: "p-dup",
            state: .executed,
            payloadHash: hash,
            snapshotRevision: 1,
            recordedAt: t0
        ))
        XCTAssertThrowsError(
            try ledger.database.write { db in
                try db.execute(sql: """
                    INSERT INTO fl_assistant_receipt
                        (proposalID, state, payloadHash, snapshotRevision, recordedAt)
                    VALUES ('p-dup', 'executed', NULL, NULL, '2026-10-11T12:00:05.000Z')
                    """)
            },
            "a second executed receipt for one proposal violates the unique durable claim"
        )
        let rows = try await ledger.allReceipts()
        XCTAssertEqual(rows.count, 1, "only the first executed receipt stands")
    }

    /// Round 2, item 3 (lesser-finding semantics, red-first against the
    /// pre-claim head: the approval was mislabeled `.alreadyDecided` while
    /// nothing had been decided): a proposal minted but undecided before the
    /// process ended refuses fail-closed as unresumable-in-flight. It never
    /// silently becomes "already decided", and it never executes from a
    /// stale in-memory table. Full proposal recovery is the documented PR
    /// Handoff follow-up.
    func testUndecidedProposalAfterRestartRefusesFailClosed() async throws {
        let url = tempDatabaseURL()
        let first = try GRDBReceiptLedger.open(at: url)
        try first.database.write { db in
            try db.execute(sql: "CREATE TABLE fl_test_effects (proposalID TEXT NOT NULL)")
        }
        let authority1 = try makeAuthority(ledger: first, id: "proposal-orphan")
        let orphan = try await authority1.propose(
            tool: .proposeStepAdvance,
            payload: .stepAdvance(stepIndex: 2),
            against: try makeSnapshot(),
            now: t0
        )  // minted, never decided
        // Process restart: a fresh authority over the same ledger.
        let second = try GRDBReceiptLedger.open(at: url)
        try second.database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS fl_test_effects (proposalID TEXT NOT NULL)")
        }
        let authority2 = try makeAuthority(ledger: second, id: "proposal-orphan")
        await expectError(.proposalInFlight(proposalID: "proposal-orphan")) {
            try await authority2.approve(
                try makeApproval(for: orphan),
                executor: InsertExecutor(),
                sessionID: "s1",
                now: t0.addingTimeInterval(4)
            )
        }
        XCTAssertEqual(try effectCount(second), 0, "an unresumable proposal never executes")
    }
}
