import Foundation
import FLDomain
import FLPersistence
import GRDB

// MARK: - Durable receipts
// The ledger is the execution evidence store: "A receipt is the only execution
// evidence anyone may trust" (FLDomain). Rows survive restarts, which is what
// makes replay approval impossible across process lifetimes.

/// An executor whose effects can join the ledger's transaction: it writes
/// through the open connection instead of its own store, so the effects and
/// the executed receipt commit together or not at all. This is the atomicity
/// the spec requires for device timers (a timer that exists without its
/// executed receipt, or the reverse, is corruption).
public protocol GRDBActionExecutor: Sendable {
    /// Apply the proposal's effects on the open transaction connection.
    /// Synchronous by design: everything inside a transaction is.
    func apply(_ payload: ActionPayload, proposal: ActionProposal, in db: Database) throws
}

/// Versioned migrations for the assistant layer, composed ON TOP of the
/// FLPersistence baseline. Part 1's registry is never edited (the package is
/// under review): this migrator runs the baseline first, then appends the
/// assistant tables — new migrations only, matching FLPersistence's rules.
public enum FLAssistantMigrations {
    public static func migrator() -> DatabaseMigrator {
        var migrator = FLSchemaMigrations.migrator()
        migrator.registerMigration("v2-assistant-receipts") { db in
            try db.execute(sql: """
                CREATE TABLE fl_assistant_receipt (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    proposalID TEXT NOT NULL,
                    state TEXT NOT NULL,
                    payloadHash TEXT,
                    snapshotRevision INTEGER,
                    recordedAt TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX fl_assistant_receipt_proposal
                ON fl_assistant_receipt(proposalID)
                """)
        }
        return migrator
    }
}

/// GRDB-backed receipt ledger. Dates are stored as FLTimestamp ISO 8601
/// strings (the cross-language contract form), and every row is rebuilt
/// through `ActionReceipt`'s throwing initializer when read, so a corrupted
/// row refuses loudly instead of yielding an unvalidated receipt.
public struct GRDBReceiptLedger: ReceiptLedger, Sendable {
    /// The underlying app database (WAL pool or in-memory queue). Exposed for
    /// tests and diagnostics on the same writer.
    public let database: AppDatabase

    /// - Parameters:
    ///   - database: the app database to own the receipt table.
    ///   - applyMigrations: run `FLAssistantMigrations` on init. Pass `false`
    ///     only when the caller migrates explicitly.
    public init(database: AppDatabase, applyMigrations: Bool = true) throws {
        self.database = database
        if applyMigrations {
            try FLAssistantMigrations.migrator().migrate(database.dbWriter)
        }
    }

    /// Open (and migrate) a ledger over an on-disk WAL database.
    public static func open(at url: URL) throws -> GRDBReceiptLedger {
        try self.init(database: AppDatabase.open(at: url))
    }

    /// An in-memory ledger with the same migrations — tests and previews.
    public static func inMemory() throws -> GRDBReceiptLedger {
        try self.init(database: AppDatabase.inMemory())
    }

    // MARK: ReceiptLedger

    public func record(_ receipt: ActionReceipt) async throws {
        try await database.dbWriter.write { db in
            try Self.insert(receipt, in: db)
        }
    }

    public func latestReceipt(proposalID: String) async throws -> ActionReceipt? {
        try await database.dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM fl_assistant_receipt
                    WHERE proposalID = ? ORDER BY id DESC LIMIT 1
                    """,
                arguments: [proposalID]
            )
            return try row.map(Self.receipt(from:))
        }
    }

    // MARK: Atomic execution

    /// Execute the proposal's effects and persist the executed receipt in ONE
    /// transaction. Authorization is the authority's job and has happened by
    /// the time this runs; if the effects throw, nothing commits — no
    /// executed receipt for work that did not happen, and no half-applied
    /// effects behind a receipt.
    @discardableResult
    public func executeAndRecord(
        proposal: ActionProposal,
        executor: any GRDBActionExecutor,
        recordedAt: Date
    ) async throws -> ActionReceipt {
        try await database.dbWriter.write { db in
            try executor.apply(proposal.payload, proposal: proposal, in: db)
            let receipt = try ActionReceipt(
                proposalID: proposal.id,
                state: .executed,
                payloadHash: proposal.payloadHash,
                snapshotRevision: proposal.snapshotRevision,
                recordedAt: recordedAt
            )
            try Self.insert(receipt, in: db)
            return receipt
        }
    }

    // MARK: Reads for tests and diagnostics

    /// Every receipt row, oldest first, across all proposals.
    public func allReceipts() async throws -> [ActionReceipt] {
        try await database.dbWriter.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM fl_assistant_receipt ORDER BY id ASC"
            )
            return try rows.map(Self.receipt(from:))
        }
    }

    // MARK: Row mapping

    fileprivate static func insert(_ receipt: ActionReceipt, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fl_assistant_receipt
                    (proposalID, state, payloadHash, snapshotRevision, recordedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                receipt.proposalID,
                receipt.state.rawValue,
                receipt.payloadHash,
                receipt.snapshotRevision,
                FLTimestamp.encode(receipt.recordedAt),
            ]
        )
    }

    private static func receipt(from row: Row) throws -> ActionReceipt {
        let stateRaw = row["state"] as String?
        guard let state = stateRaw.flatMap(ActionReceiptState.init(rawValue:)) else {
            throw FLAssistantError.corruptLedgerRow(
                detail: "unknown receipt state '\(stateRaw ?? "nil")'"
            )
        }
        let recordedRaw = row["recordedAt"] as String?
        let recorded = try recordedRaw.map { try FLTimestamp.decode($0, target: "ActionReceipt.recordedAt") }
        guard let recordedAt = recorded else {
            throw FLAssistantError.corruptLedgerRow(detail: "receipt recordedAt is missing or not text")
        }
        guard let proposalID = row["proposalID"] as String? else {
            throw FLAssistantError.corruptLedgerRow(detail: "receipt proposalID is missing")
        }
        return try ActionReceipt(
            proposalID: proposalID,
            state: state,
            payloadHash: row["payloadHash"] as String?,
            snapshotRevision: row["snapshotRevision"] as Int?,
            recordedAt: recordedAt
        )
    }
}
