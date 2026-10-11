import Foundation

public enum CheckpointStoreError: Error, Equatable {
    /// File unreadable or not valid envelope JSON.
    case corrupt(String)
    /// Envelope decoded but payload bytes do not match the stored checksum.
    case checksumMismatch
    case unsupportedSchemaVersion(Int)
    case writeFailed(String)
    case notFound
}

/// Envelope framing one checkpoint file: schema version, content checksum,
/// and the checkpoint payload bytes.
struct CheckpointEnvelope: Codable {
    var schemaVersion: Int
    var checksum: String
    var payload: Data
}

/// File-backed, versioned checkpoint store. One JSON file per session:
/// `<directory>/cooking-session-<sessionID>.json`. Writes are atomic;
/// reads verify the content checksum before decoding and are idempotent —
/// repeated reads of the same bytes return the same checkpoint or the same
/// error. Corrupt reads throw; they never crash and never fabricate state.
public final class CookingSessionStore {
    public let directory: URL
    private let fm: FileManager

    private static let filePrefix = "cooking-session-"
    private static let fileSuffix = ".json"

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fm = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(Self.filePrefix + sessionID.uuidString + Self.fileSuffix)
    }

    public func existingSessionIDs() -> [UUID] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(Self.fileSuffix) }
            .compactMap { UUID(uuidString: String($0.dropFirst(Self.filePrefix.count).dropLast(Self.fileSuffix.count))) }
            .sorted()
    }

    public func save(_ checkpoint: CookingCheckpoint) throws {
        var updated = checkpoint
        updated.savedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(updated)
        } catch {
            throw CheckpointStoreError.writeFailed("payload encode failed: \(error.localizedDescription)")
        }

        let envelope = CheckpointEnvelope(
            schemaVersion: CookingCheckpoint.schemaVersion,
            checksum: RecipeFingerprint.fnv1a64(String(decoding: payload, as: UTF8.self)),
            payload: payload
        )
        let envelopeData: Data
        do {
            envelopeData = try JSONEncoder().encode(envelope)
        } catch {
            throw CheckpointStoreError.writeFailed("envelope encode failed: \(error.localizedDescription)")
        }

        do {
            try envelopeData.write(to: fileURL(for: updated.identity.sessionID), options: .atomic)
        } catch {
            throw CheckpointStoreError.writeFailed("\(error.localizedDescription)")
        }
    }

    public func load(sessionID: UUID) throws -> CookingCheckpoint {
        let url = fileURL(for: sessionID)
        guard fm.fileExists(atPath: url.path) else { throw CheckpointStoreError.notFound }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CheckpointStoreError.corrupt("unreadable: \(error.localizedDescription)")
        }

        let envelope: CheckpointEnvelope
        do {
            envelope = try JSONDecoder().decode(CheckpointEnvelope.self, from: data)
        } catch {
            throw CheckpointStoreError.corrupt("envelope: \(error.localizedDescription)")
        }

        guard RecipeFingerprint.fnv1a64(String(decoding: envelope.payload, as: UTF8.self)) == envelope.checksum else {
            throw CheckpointStoreError.checksumMismatch
        }
        guard envelope.schemaVersion == CookingCheckpoint.schemaVersion else {
            throw CheckpointStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(CookingCheckpoint.self, from: envelope.payload)
        } catch {
            throw CheckpointStoreError.corrupt("payload: \(error.localizedDescription)")
        }
    }

    /// All checkpoints currently in a resumable (active) phase. Files that are
    /// corrupt are skipped here; `load(sessionID:)` surfaces them strictly for
    /// callers that need to distinguish "nothing saved" from "saved but
    /// unreadable".
    public func resumableSessions() -> [CookingCheckpoint] {
        existingSessionIDs().compactMap { id in
            (try? load(sessionID: id)) ?? nil
        }
        .filter { $0.phase == .active }
    }

    public func deleteCheckpoint(sessionID: UUID) {
        try? fm.removeItem(at: fileURL(for: sessionID))
    }
}
