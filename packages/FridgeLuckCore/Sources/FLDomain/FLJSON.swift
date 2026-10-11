import Foundation

/// Shared JSON rules for every FLDomain type and fixture. The full contract is
/// documented in `Fixtures/README.md`; the rules the code enforces are:
///
/// - Timestamps are ISO 8601 strings in UTC. Encoders always emit millisecond
///   precision (the shape JavaScript's `Date.toISOString()` produces); decoders
///   accept fractional seconds or none, so Swift, TypeScript and Python can all
///   produce and consume the same files.
/// - Canonical encoders sort keys and pretty-print, so decoding a fixture and
///   re-encoding it is byte-stable.
/// - Fixture envelopes carry a `schema` string that decoders check explicitly
///   (`FLSchema`); an unknown major version is refused.
public enum FLJSON {
    /// A fresh canonical encoder per call: encoders are cheap and must not be
    /// shared across concurrently running tests.
    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func canonicalDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Canonical JSON bytes of a Codable value — the input for payload hashing
    /// (see `ActionProposal`; the hash function itself is policy in the
    /// assistant core, not here).
    public static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try canonicalEncoder().encode(value)
    }
}

/// ISO 8601 UTC timestamp codec shared by every Codable type with a `Date`.
public enum FLTimestamp {
    public static func encode(_ date: Date) -> String {
        // Millisecond precision, matching JavaScript Date.toISOString().
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    public static func decode(_ raw: String, target: String) throws -> Date {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        withFractional.timeZone = TimeZone(identifier: "UTC")
        if let date = withFractional.date(from: raw) { return date }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        withoutFractional.timeZone = TimeZone(identifier: "UTC")
        if let date = withoutFractional.date(from: raw) { return date }

        throw FLDomainError.validation(
            target: target,
            reason: "timestamp is not an ISO 8601 UTC instant: \(raw)"
        )
    }
}

/// The fixture schema version rule.
///
/// Every frozen fixture file carries a top-level `"schema"` string. Decoders
/// accept `"fldomain.v1"` and additive minor versions of the form
/// `"fldomain.v1.<n>"` (a minor addition must remain readable by every v1
/// decoder). Anything else — `fldomain.v2`, an unknown prefix, a typo — is
/// refused with `.unsupportedSchemaVersion`, never reinterpreted. Bumping the
/// major version is a breaking change that requires shipping new decoders first.
public enum FLSchema {
    public static let acceptedMajor: String = "fldomain.v1"

    public static func validate(_ raw: String) throws {
        if raw == acceptedMajor { return }
        let prefix = acceptedMajor + "."
        guard raw.hasPrefix(prefix), Int(raw.dropFirst(prefix.count)) != nil else {
            throw FLDomainError.unsupportedSchemaVersion(found: raw, supported: acceptedMajor)
        }
    }
}
