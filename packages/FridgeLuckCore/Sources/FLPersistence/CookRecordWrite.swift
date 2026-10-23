import Foundation
import GRDB
import FLDomain

// MARK: - The finished-cook pair (review round 2, item 1)
//
// A completed cook and its preference event persist together or not at all
// (project overview: "cook and preference-event records are designed to
// persist as an atomic pair"). The pair's halves are the `fl_cooks` and
// `fl_preference_events` tables (migration `v2-cooks-preference-events`);
// the single-transaction write below is the atomic foundation primitive the
// flow layer builds on (it adds inventory consumption and the nutrition
// snapshot on top).
//
// Atomicity comes from GRDB's transaction semantics: `dbWriter.write` runs
// the block in one transaction and rolls the whole thing back when the block
// throws — including when the failure is injected between the two inserts by
// the internal `betweenWrites` seam the rollback test uses.

// MARK: Column encoding

/// A compact, deterministic JSON encoding for nested values stored in TEXT
/// columns (`substitutions`, ingredient references). Column storage is not
/// the wire contract, so this differs from the file-canonical pretty form:
/// sorted keys keep the bytes stable for hashing and diffs; the timestamp
/// strategy keeps any future `Date` field inside the canonical ISO-8601 rule.
private func columnJSONData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(FLTimestamp.encode(date))
    }
    return try encoder.encode(value)
}

private func columnJSONString<T: Encodable>(_ value: T?) throws -> String? {
    guard let value else { return nil }
    return String(decoding: try columnJSONData(value), as: UTF8.self)
}

/// Stored enum raw values were validated by the domain before insert; an
/// unrecognized raw value on read means the store was modified outside the
/// domain (or written by an incompatible schema). Refuse it explicitly —
/// reads fail closed, never reinterpret.
private func storedEnum<E: RawRepresentable>(_ raw: String, as type: E.Type, table: String, column: String) throws -> E where E.RawValue == String {
    guard let value = type.init(rawValue: raw) else {
        throw FLPersistenceError.corruptRecord(
            table: table, column: column, value: raw, reason: "unrecognized raw value"
        )
    }
    return value
}

private func optionalStoredEnum<E: RawRepresentable>(_ raw: String?, as type: E.Type, table: String, column: String) throws -> E? where E.RawValue == String {
    guard let raw else { return nil }
    return try storedEnum(raw, as: type, table: table, column: column)
}

/// Decode a JSON column. Any decode failure is storage corruption from this
/// layer's point of view: the column was not written by this module's encoder.
private func columnJSON<T: Decodable>(_ raw: String, as type: T.Type, table: String, column: String) throws -> T {
    do {
        return try FLJSON.canonicalDecoder().decode(type, from: Data(raw.utf8))
    } catch {
        throw FLPersistenceError.corruptRecord(
            table: table, column: column, value: raw, reason: "\(error)"
        )
    }
}

private func optionalColumnJSON<T: Decodable>(_ raw: String?, as type: T.Type, table: String, column: String) throws -> T? {
    guard let raw else { return nil }
    return try columnJSON(raw, as: type, table: table, column: column)
}

private func optionalTimestamp(_ raw: String?, target: String) throws -> Date? {
    guard let raw else { return nil }
    return try FLTimestamp.decode(raw, target: target)
}

// MARK: fl_cooks

/// Row mapping for `fl_cooks`. Internal: the public surface is the paired
/// write and the readers on `AppDatabase`.
enum FLCookRecord {
    static let table = "fl_cooks"

    static func insert(_ cook: Cook, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO fl_cooks (
                id, recipe_source, recipe_source_id, recipe_revision, servings,
                substitutions, rating, note, started_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                cook.id,
                cook.recipeRevision.source.rawValue,
                cook.recipeRevision.sourceRecipeID,
                cook.recipeRevision.revision,
                cook.servings,
                String(decoding: try columnJSONData(cook.substitutions), as: UTF8.self),
                cook.rating,
                cook.note,
                cook.startedAt.map(FLTimestamp.encode),
                FLTimestamp.encode(cook.completedAt),
            ])
    }

    static func fetch(id: String, from db: Database) throws -> Cook? {
        try Row.fetchOne(db, sql: "SELECT * FROM fl_cooks WHERE id = ?", arguments: [id])
            .map(decode(_:))
    }

    private static func decode(_ row: Row) throws -> Cook {
        try Cook(
            id: row["id"],
            recipeRevision: try RecipeKey(
                source: try storedEnum(
                    row["recipe_source"], as: RecipeSource.self,
                    table: table, column: "recipe_source"
                ),
                sourceRecipeID: row["recipe_source_id"],
                revision: row["recipe_revision"]
            ),
            servings: row["servings"],
            substitutions: try columnJSON(
                row["substitutions"], as: [CookSubstitution].self,
                table: table, column: "substitutions"
            ),
            rating: row["rating"],
            note: row["note"],
            startedAt: try optionalTimestamp(row["started_at"], target: "\(table).started_at"),
            completedAt: try FLTimestamp.decode(row["completed_at"], target: "\(table).completed_at")
        )
    }
}

// MARK: fl_preference_events

/// Row mapping for `fl_preference_events`.
enum FLPreferenceEventRecord {
    static let table = "fl_preference_events"

    static func insert(_ event: PreferenceEvent, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO fl_preference_events (
                id, kind, timestamp, recipe_source, recipe_source_id, recipe_revision,
                exposure_id, source, supersedes_event_id, supersedes_mode,
                rating, would_repeat, note, ingredient_name, from_ingredient, to_ingredient,
                sentence_id, verdict
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id.rawValue,
                event.kind.rawValue,
                FLTimestamp.encode(event.timestamp),
                event.recipeRevision.source.rawValue,
                event.recipeRevision.sourceRecipeID,
                event.recipeRevision.revision,
                event.exposureID,
                event.source.rawValue,
                event.supersedes?.priorEventID.rawValue,
                event.supersedes?.mode.rawValue,
                event.rating,
                event.wouldRepeat.map { $0 ? 1 : 0 },
                event.note,
                event.ingredientName,
                try columnJSONString(event.fromIngredient),
                try columnJSONString(event.toIngredient),
                event.sentenceID,
                event.verdict?.rawValue,
            ])
    }

    static func fetch(id: String, from db: Database) throws -> PreferenceEvent? {
        try Row.fetchOne(db, sql: "SELECT * FROM fl_preference_events WHERE id = ?", arguments: [id])
            .map(decode(_:))
    }

    private static func decode(_ row: Row) throws -> PreferenceEvent {
        let supersedesEventID: String? = row["supersedes_event_id"]
        let supersedesModeRaw: String? = row["supersedes_mode"]
        var supersedes: EventCorrection?
        if let supersedesEventID, let supersedesModeRaw {
            supersedes = try EventCorrection(
                priorEventID: PreferenceEventID(supersedesEventID),
                mode: try storedEnum(
                    supersedesModeRaw, as: EventCorrection.Mode.self,
                    table: table, column: "supersedes_mode"
                )
            )
        } else if supersedesEventID != nil || supersedesModeRaw != nil {
            // The table's CHECK constraint already forbids half-set correction
            // columns; treat any violation as corruption rather than dropping
            // one side of the reference.
            throw FLPersistenceError.corruptRecord(
                table: table, column: "supersedes_event_id",
                value: supersedesEventID ?? "NULL",
                reason: "supersedes columns are half-set"
            )
        }

        return try PreferenceEvent(
            id: row["id"],
            kind: try storedEnum(
                row["kind"], as: PreferenceEventKind.self,
                table: table, column: "kind"
            ),
            timestamp: try FLTimestamp.decode(row["timestamp"], target: "\(table).timestamp"),
            recipeRevision: try RecipeKey(
                source: try storedEnum(
                    row["recipe_source"], as: RecipeSource.self,
                    table: table, column: "recipe_source"
                ),
                sourceRecipeID: row["recipe_source_id"],
                revision: row["recipe_revision"]
            ),
            source: try storedEnum(
                row["source"], as: PreferenceEventSource.self,
                table: table, column: "source"
            ),
            exposureID: row["exposure_id"],
            supersedes: supersedes,
            rating: row["rating"],
            wouldRepeat: (row["would_repeat"] as Int?).map { $0 != 0 },
            note: row["note"],
            ingredientName: row["ingredient_name"],
            fromIngredient: try optionalColumnJSON(
                row["from_ingredient"], as: IngredientReference.self,
                table: table, column: "from_ingredient"
            ),
            toIngredient: try optionalColumnJSON(
                row["to_ingredient"], as: IngredientReference.self,
                table: table, column: "to_ingredient"
            ),
            sentenceID: row["sentence_id"],
            verdict: try optionalStoredEnum(
                row["verdict"], as: ProfileSentenceVerdict.self,
                table: table, column: "verdict"
            )
        )
    }
}

// MARK: - The paired write

extension AppDatabase {
    /// Persist the finished-cook pair atomically: the cook row and the
    /// preference-event row are written in one transaction — both persist, or
    /// neither does. This is the foundation primitive; the flow layer wraps
    /// it with inventory consumption and the nutrition snapshot.
    public func writeCompletedCook(_ cook: Cook, preferenceEvent: PreferenceEvent) throws {
        try writeCompletedCook(cook, preferenceEvent: preferenceEvent, betweenWrites: nil)
    }

    /// The same write with the rollback-test seam: `betweenWrites` runs after
    /// the cook insert and before the event insert, inside the transaction —
    /// exactly the gap an injected failure must fall into to prove the pair
    /// cannot persist half-written.
    func writeCompletedCook(
        _ cook: Cook,
        preferenceEvent: PreferenceEvent,
        betweenWrites: ((Database) throws -> Void)?
    ) throws {
        try dbWriter.write { db in
            try FLCookRecord.insert(cook, into: db)
            try betweenWrites?(db)
            try FLPreferenceEventRecord.insert(preferenceEvent, into: db)
        }
    }

    /// The persisted cook with this id, or nil.
    public func completedCook(id: String) throws -> Cook? {
        try dbWriter.read { db in
            try FLCookRecord.fetch(id: id, from: db)
        }
    }

    /// The persisted preference event with this id, or nil.
    public func preferenceEvent(id: String) throws -> PreferenceEvent? {
        try dbWriter.read { db in
            try FLPreferenceEventRecord.fetch(id: id, from: db)
        }
    }
}
