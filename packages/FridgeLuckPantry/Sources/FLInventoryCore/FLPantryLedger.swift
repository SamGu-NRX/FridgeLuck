import Foundation
import FLDomain
import FLPersistence
import GRDB

// MARK: - The pantry ledger
// Append-only stock events in GRDB, folded to current stock by `FLStockFold`.
// Engineering-plan style (E04): versioned, additive, namespaced migrations
// ("fl-pantry-v1") so the central registry in FLPersistence can adopt them
// verbatim later; one serialized writer; every apply atomic.
//
// Invariants enforced here, each with a test:
// - Idempotent retries: applying an event whose command ID was already
//   applied answers `.alreadyApplied` and changes nothing (a retried
//   confirmation never adds stock twice).
// - Event identity is immutable: the same event ID under a different command
//   is refused.
// - A refused event mutates nothing: the validation fold runs before the
//   insert, inside the same transaction.
// - Households never mix: reads, folds and writes are scoped to the event's
//   household; a ledger opened with an allowed household refuses others.

public struct FLPantryLedger: Sendable {
    private let dbWriter: any DatabaseWriter
    /// When set (first release: one household per phone), events for any
    /// other household are refused instead of silently mixed.
    private let allowedHouseholdID: FLHouseholdID?

    public init(dbWriter: any DatabaseWriter, allowedHouseholdID: FLHouseholdID? = nil) throws {
        self.dbWriter = dbWriter
        self.allowedHouseholdID = allowedHouseholdID
        try Self.migrations().migrate(dbWriter)
    }

    public init(db: AppDatabase, allowedHouseholdID: FLHouseholdID? = nil) throws {
        try self.init(dbWriter: db.dbWriter, allowedHouseholdID: allowedHouseholdID)
    }

    /// This target's own migrations. Namespaced with the `fl-pantry-` prefix:
    /// they never touch FLPersistence's registry and can be adopted into it
    /// verbatim when the packages graft together.
    public static func migrations() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fl-pantry-v1") { db in
            try db.execute(sql: """
                CREATE TABLE fl_pantry_stock_event (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL,
                    household_id TEXT NOT NULL,
                    command_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT NOT NULL,
                    ingredient_group_key TEXT NOT NULL,
                    ingredient_json TEXT NOT NULL,
                    quantity_json TEXT NOT NULL,
                    lot_id TEXT,
                    cook_id TEXT,
                    preparation TEXT,
                    prior_event_id TEXT,
                    correction_mode TEXT,
                    event_timestamp TEXT NOT NULL,
                    ingested_at TEXT NOT NULL,
                    UNIQUE (household_id, event_id)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX fl_pantry_event_item
                    ON fl_pantry_stock_event (household_id, ingredient_group_key)
                """)
            try db.execute(sql: """
                CREATE TABLE fl_pantry_applied_command (
                    household_id TEXT NOT NULL,
                    command_id TEXT NOT NULL,
                    applied_at TEXT NOT NULL,
                    PRIMARY KEY (household_id, command_id)
                )
                """)
        }
        return migrator
    }

    // MARK: Applying events

    /// The outcome of applying one event. `.alreadyApplied` is success under
    /// retry: the event is on the ledger exactly once.
    public enum ApplyOutcome: Equatable, Sendable {
        case applied
        case alreadyApplied
    }

    /// Apply one event atomically: validate against the household's full
    /// history (fold), then append. Retries with the same command ID are
    /// idempotent; anything that fails validation leaves the ledger
    /// untouched.
    @discardableResult
    public func apply(_ event: FLStockEvent) throws -> ApplyOutcome {
        try applyBatch([event])
    }

    /// Apply a batch of events as ONE command, atomically: a receipt with
    /// several lines, or a cook's consumption of several ingredients, either
    /// lands whole or not at all. Retries with the same command ID are
    /// idempotent.
    @discardableResult
    public func applyBatch(_ events: [FLStockEvent]) throws -> ApplyOutcome {
        guard !events.isEmpty else {
            throw FLInventoryError.invalidEvent(eventID: "(batch)", reason: "a command carries at least one event")
        }
        let commandID = events[0].commandID
        for event in events {
            guard event.commandID == commandID else {
                throw FLInventoryError.invalidEvent(
                    eventID: event.id.rawValue,
                    reason: "all events in one command share the command ID"
                )
            }
            if let allowed = allowedHouseholdID, event.householdID != allowed {
                throw FLInventoryError.householdMismatch(eventID: event.id.rawValue)
            }
        }

        let outcome: ApplyOutcome = try dbWriter.write { db in
            if try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM fl_pantry_applied_command WHERE household_id = ? AND command_id = ?",
                arguments: [events[0].householdID.rawValue, commandID]
            ) != nil {
                // Already applied: an idempotent retry changes nothing.
                return .alreadyApplied
            }

            for event in events {
                let sameEventID = try Row.fetchOne(
                    db,
                    sql: "SELECT command_id FROM fl_pantry_stock_event WHERE household_id = ? AND event_id = ?",
                    arguments: [event.householdID.rawValue, event.id.rawValue]
                )
                if sameEventID != nil {
                    throw FLInventoryError.duplicateEventID(eventID: event.id.rawValue)
                }
            }

            // Validate the whole resulting history before anything is written.
            let householdID = events[0].householdID
            let history = try Self.fetchEvents(householdID: householdID, db: db)
            _ = try FLStockFold.fold(events: history + events)

            let ingestedAt = FLTimestamp.encode(Date())
            for event in events {
                try Self.insert(event, db: db, ingestedAt: ingestedAt)
            }
            try db.execute(sql: """
                INSERT INTO fl_pantry_applied_command (household_id, command_id, applied_at)
                VALUES (?, ?, ?)
                """, arguments: [events[0].householdID.rawValue, commandID, ingestedAt])
            return .applied
        }
        return outcome
    }

    // MARK: Reading

    /// The household's events in ingestion order — the ledger's full truth,
    /// including superseded events (corrections supersede, they never erase).
    public func events(householdID: FLHouseholdID) throws -> [FLStockEvent] {
        try dbWriter.read { db in
            try Self.fetchEvents(householdID: householdID, db: db)
        }
    }

    /// Current stock as evidence: one `FLPantryLot` per open lot, oldest
    /// first. This is the bounded snapshot feasibility consumes and the
    /// backend reads (SPEC §4).
    public func snapshot(householdID: FLHouseholdID) throws -> [FLPantryLot] {
        try dbWriter.read { db in
            let stock = try FLStockFold.fold(events: Self.fetchEvents(householdID: householdID, db: db))
            return stock.flatMap(\.lots)
        }
    }

    /// Current stock of one ingredient identity (by group key).
    public func itemStock(householdID: FLHouseholdID, ingredient: IngredientReference) throws -> FLItemStock? {
        let key = FLStockFold.groupKey(for: ingredient)
        return try dbWriter.read { db in
            let stock = try FLStockFold.fold(events: Self.fetchEvents(householdID: householdID, db: db))
            return stock.first(where: { $0.groupKey == key })
        }
    }

    /// Whether a command ID was already applied (for receipts and audits).
    public func hasCommand(householdID: FLHouseholdID, commandID: String) throws -> Bool {
        try dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM fl_pantry_applied_command WHERE household_id = ? AND command_id = ?",
                arguments: [householdID.rawValue, commandID]
            ) != nil
        }
    }

    // MARK: Row mapping

    private static func insert(_ event: FLStockEvent, db: Database, ingestedAt: String) throws {
        try db.execute(sql: """
            INSERT INTO fl_pantry_stock_event (
                event_id, household_id, command_id, kind, source,
                ingredient_group_key, ingredient_json, quantity_json,
                lot_id, cook_id, preparation, prior_event_id, correction_mode,
                event_timestamp, ingested_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id.rawValue,
                event.householdID.rawValue,
                event.commandID,
                event.kind.rawValue,
                event.source.rawValue,
                FLStockFold.groupKey(for: event.ingredient),
                String(decoding: FLJSON.canonicalData(event.ingredient), as: UTF8.self),
                String(decoding: FLJSON.canonicalData(event.quantity), as: UTF8.self),
                event.lotID,
                event.cookID,
                event.preparation,
                event.supersedes?.priorEventID.rawValue,
                event.supersedes?.mode.rawValue,
                FLTimestamp.encode(event.timestamp),
                ingestedAt,
            ])
    }

    private static func fetchEvents(householdID: FLHouseholdID, db: Database) throws -> [FLStockEvent] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT event_id, household_id, command_id, kind, source,
                       ingredient_json, quantity_json, lot_id, cook_id, preparation,
                       prior_event_id, correction_mode, event_timestamp
                FROM fl_pantry_stock_event
                WHERE household_id = ?
                ORDER BY sequence ASC
                """,
            arguments: [householdID.rawValue]
        )
        return try rows.map { row in
            let ingredientRaw: String = try row.get("ingredient_json")
            let quantityRaw: String = try row.get("quantity_json")
            let ingredient = try FLJSON.canonicalDecoder().decode(
                IngredientReference.self,
                from: Data(ingredientRaw.utf8)
            )
            let quantity = try FLJSON.canonicalDecoder().decode(
                QuantityEvidence.self,
                from: Data(quantityRaw.utf8)
            )
            let priorRaw: String? = try row.get("prior_event_id")
            let modeRaw: String? = try row.get("correction_mode")
            var supersedes: FLStockCorrection?
            if let priorRaw, let modeRaw {
                guard let mode = FLStockCorrection.Mode(rawValue: modeRaw) else {
                    throw FLDomainError.validation(
                        target: "FLStockCorrection.mode",
                        reason: "unknown correction mode \(modeRaw) stored in the ledger"
                    )
                }
                supersedes = FLStockCorrection(priorEventID: try StockEventID(priorRaw), mode: mode)
            }
            guard let kind = FLStockEventKind(rawValue: try row.get("kind")) else {
                throw FLDomainError.validation(
                    target: "FLStockEvent.kind",
                    reason: "unknown event kind stored in the ledger"
                )
            }
            guard let source = FLStockEventSource(rawValue: try row.get("source")) else {
                throw FLDomainError.validation(
                    target: "FLStockEvent.source",
                    reason: "unknown event source stored in the ledger"
                )
            }
            let eventTimestampRaw: String = try row.get("event_timestamp")
            return try FLStockEvent(
                id: try row.get("event_id"),
                commandID: try row.get("command_id"),
                householdID: FLHouseholdID(try row.get("household_id")),
                kind: kind,
                ingredient: ingredient,
                quantity: quantity,
                lotID: try row.get("lot_id"),
                cookID: try row.get("cook_id"),
                preparation: try row.get("preparation"),
                source: source,
                timestamp: try FLTimestamp.decode(eventTimestampRaw, target: "FLStockEvent.timestamp"),
                supersedes: supersedes
            )
        }
    }
}
