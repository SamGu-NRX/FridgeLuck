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
