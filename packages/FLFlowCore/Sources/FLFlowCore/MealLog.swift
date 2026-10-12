import Foundation
import GRDB
import FLDomain
import FLPersistence

// MARK: - Flow schema
// The flow package owns its tables the way the engineering plan assigns them:
// registered as their own GRDB migration IDs, additive, never editing the
// baseline FLPersistence owns. GRDB records applied IDs in the shared
// registry table, so applying here composes with the app's migrations and is
// idempotent.
//
// Part 2 (pantry truth) and Part 5 (integration) will add their own
// migrations the same way; consumption events and nutrition snapshots join
// the hand-off when their owning parts land (see the PR Handoff).

public enum FlowMigrations {
    /// The flow's migrations. IDs are ordered after the baseline ("v1-baseline").
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v2 — the meal-log hand-off tables. Payloads are the canonical
        // FLJSON of the domain values (sorted keys, ISO 8601 timestamps);
        // the indexed columns are query conveniences, the payload is the
        // authoritative record and decodes through the throwing initializers.
        migrator.registerMigration("v2-flflow-meallog") { db in
            try db.execute(sql: """
                CREATE TABLE flflow_cooks (
                    id TEXT PRIMARY KEY,
                    recipeSourceID TEXT NOT NULL,
                    recipeRevision INTEGER NOT NULL,
                    completedAtEpochSeconds REAL NOT NULL,
                    payload TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE flflow_preference_events (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    recipeSourceID TEXT NOT NULL,
                    recipeRevision INTEGER NOT NULL,
                    timestampEpochSeconds REAL NOT NULL,
                    payload TEXT NOT NULL
                )
                """)
        }

        return migrator
    }

    /// Applies the flow's pending migrations. Safe to call repeatedly and
    /// alongside `AppDatabase.migrate()` (the baseline).
    public static func apply(to dbWriter: any DatabaseWriter) throws {
        try migrator().migrate(dbWriter)
    }
}

// MARK: - Meal log
// SPEC 3.3/3.4: finishing a cook commits the Cook record and its
// cookCompleted PreferenceEvent together, in one transaction — both rows or
// neither. The event mirrors the cook (same rating, note, revision, instant),
// so the two records cannot disagree by construction.

public enum MealLog {
    /// The hand-off pair: one finished cook and its preference event.
    public struct Handoff: Hashable, Sendable {
        public let cook: Cook
        public let event: PreferenceEvent

        public init(cook: Cook, event: PreferenceEvent) {
            self.cook = cook
            self.event = event
        }
    }

    /// Builds the hand-off pair from a finished session and the user's
    /// verdict. Refuses sessions that are not finished: a cook is logged
    /// only when the session reached the end.
    public static func makeHandoff(
        session: CookSession,
        cookID: String,
        eventID: String,
        servings: Int,
        rating: Int,
        wouldRepeat: Bool,
        note: String?,
        startedAt: Date?
    ) throws -> Handoff {
        guard session.stage == .finished else {
            throw FLFlowError.mealLogRefused(reason: "a cook is logged only from a finished session (got \(String(describing: session.stage)))")
        }
        if let startedAt {
            guard session.checkpoint.updatedAt >= startedAt else {
                throw FLFlowError.mealLogRefused(reason: "the session's last checkpoint precedes its start")
            }
        }
        let cook = try Cook(
            id: cookID,
            recipeRevision: session.checkpoint.recipeRevision,
            servings: servings,
            substitutions: session.acceptedSubstitutions,
            rating: rating,
            note: note,
            startedAt: startedAt,
            completedAt: session.checkpoint.updatedAt
        )
        // The event mirrors the cook — one source of truth for rating, note,
        // revision and instant. cookCompleted validates rating 1...5 and a
        // wouldRepeat verdict at construction.
        let event = try PreferenceEvent(
            id: eventID,
            kind: .cookCompleted,
            timestamp: cook.completedAt,
            recipeRevision: cook.recipeRevision,
            source: .appObserved,
            rating: cook.rating,
            wouldRepeat: wouldRepeat,
            note: cook.note
        )
        return Handoff(cook: cook, event: event)
    }

    /// Commits the hand-off: both rows in one transaction. A failure of
    /// either insert rolls back both — the tables can never disagree.
    public static func commit(_ handoff: Handoff, db: AppDatabase) throws {
        try FlowMigrations.apply(to: db.dbWriter)
        let cookPayload = try FLJSON.canonicalData(handoff.cook)
        let eventPayload = try FLJSON.canonicalData(handoff.event)
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO flflow_cooks
                    (id, recipeSourceID, recipeRevision, completedAtEpochSeconds, payload)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    handoff.cook.id,
                    handoff.cook.recipeRevision.sourceRecipeID,
                    handoff.cook.recipeRevision.revision,
                    handoff.cook.completedAt.timeIntervalSince1970,
                    String(decoding: cookPayload, as: UTF8.self),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO flflow_preference_events
                    (id, kind, recipeSourceID, recipeRevision, timestampEpochSeconds, payload)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    handoff.event.id.rawValue,
                    handoff.event.kind.rawValue,
                    handoff.event.recipeRevision.sourceRecipeID,
                    handoff.event.recipeRevision.revision,
                    handoff.event.timestamp.timeIntervalSince1970,
                    String(decoding: eventPayload, as: UTF8.self),
                ]
            )
        }
    }

    // MARK: Reads (payloads decode through the validated initializers)

    /// Every committed cook, oldest first, decoded from canonical payloads.
    public static func cooks(db: AppDatabase) throws -> [Cook] {
        try db.read { db in
            let payloads = try String.fetchAll(
                db,
                sql: "SELECT payload FROM flflow_cooks ORDER BY completedAtEpochSeconds, id"
            )
            return try payloads.map { payload in
                try FLJSON.canonicalDecoder().decode(Cook.self, from: Data(payload.utf8))
            }
        }
    }

    /// Every committed cookCompleted event, oldest first.
    public static func cookCompletedEvents(db: AppDatabase) throws -> [PreferenceEvent] {
        try db.read { db in
            let payloads = try String.fetchAll(
                db,
                sql: "SELECT payload FROM flflow_preference_events WHERE kind = 'cookCompleted' ORDER BY timestampEpochSeconds, id"
            )
            return try payloads.map { payload in
                try FLJSON.canonicalDecoder().decode(PreferenceEvent.self, from: Data(payload.utf8))
            }
        }
    }
}
