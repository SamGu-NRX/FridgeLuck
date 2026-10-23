import Foundation

/// A cited source. Every factual number in this library must trace to one of these.
public struct SourceRecord: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var publisher: String
    public var url: String
    /// ISO date (YYYY-MM-DD) the source was retrieved and its values copied.
    public var retrieved: String
    public var licence: String
    public var notes: String?

    public init(
        id: String, title: String, publisher: String, url: String,
        retrieved: String, licence: String, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.url = url
        self.retrieved = retrieved
        self.licence = licence
        self.notes = notes
    }
}

/// A source record as it appears inside a learn-card file. The record's id IS
/// the dictionary key it sits under ("the key is the id"), so the payload
/// carries no separate id field; decode maps keys onto SourceRecord.
public struct SourceBody: Codable, Sendable, Hashable {
    public var title: String
    public var publisher: String
    public var url: String
    /// ISO date (YYYY-MM-DD) the source was retrieved and its values copied.
    public var retrieved: String
    public var licence: String
    public var notes: String?
}

/// Thrown when two records claim one identifier within a file's scope
/// (duplicate card ids, pack ids, ingredient keys, source records). A file
/// that fails this contract throws rather than silently keeping one record.
public struct DuplicateIdError: Error, CustomStringConvertible, Sendable {
    public let subject: String
    public let id: String
    public let reason: String

    public init(subject: String, id: String, reason: String = "ids must be unique within the file") {
        self.subject = subject
        self.id = id
        self.reason = reason
    }

    public var description: String { "duplicate id in \(subject): '\(id)' — \(reason)" }
}

/// Thrown when a numeric record carries an impossible value — negative money,
/// a negative or over-scale per-100 g nutrient, a misordered range. The
/// library refuses rather than silently loading 0 or nil
/// (data/kitchen-knowledge/SCHEMA.md, "Numeric contract").
public struct InvalidNumericError: Error, CustomStringConvertible, Sendable {
    public let subject: String
    public let field: String
    /// Rendered value: Decimal and Double print sanely without generic plumbing.
    public let value: String
    public let reason: String

    public init(subject: String, field: String, value: String, reason: String) {
        self.subject = subject
        self.field = field
        self.value = value
        self.reason = reason
    }

    public var description: String {
        "invalid number in \(subject): \(field) = \(value) — \(reason)"
    }
}

/// Thrown when data would state, or compute from, a number with no cited source.
/// The library refuses rather than guesses.
public struct MissingSourceError: Error, CustomStringConvertible, Sendable {
    public let subject: String
    public let reason: String

    public init(subject: String, reason: String) {
        self.subject = subject
        self.reason = reason
    }

    public var description: String { "missing source for \(subject): \(reason)" }
}

/// The envelope every kitchen-knowledge data file carries.
public struct DataEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var kind: String
    public var retrieved: String
    public var data: Payload
}

public extension DataEnvelope {
    /// Decodes an envelope and checks its shape contract.
    static func decode(_ data: Data, expectingKind kind: String) throws -> DataEnvelope {
        let envelope = try JSONDecoder().decode(DataEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            throw MissingSourceError(
                subject: kind,
                reason: "unsupported schemaVersion \(envelope.schemaVersion) (want 1)"
            )
        }
        guard envelope.kind == kind else {
            throw MissingSourceError(subject: kind, reason: "file claims kind '\(envelope.kind)'")
        }
        return envelope
    }
}
