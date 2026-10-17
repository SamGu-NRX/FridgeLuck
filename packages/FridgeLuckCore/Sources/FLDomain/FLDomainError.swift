import Foundation

/// Errors thrown by FLDomain validated constructors and decoders.
///
/// Every rejection rule of the domain contracts (SPEC §3) throws this type, so
/// a caller can distinguish "bad input rejected at the boundary" from any other
/// failure. Each rule has a test.
public enum FLDomainError: Error, Equatable, Sendable {
    /// A field failed validation (empty, out of range, non-finite, ...).
    case validation(target: String, reason: String)

    /// A decoded payload declared a schema version this build does not support.
    /// Unknown versions are refused, never silently reinterpreted.
    case unsupportedSchemaVersion(found: String, supported: String)
}

extension FLDomainError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .validation(target, reason):
            return "FLDomain validation failed for \(target): \(reason)"
        case let .unsupportedSchemaVersion(found, supported):
            return "FLDomain refused payload: unsupported schema version \(found); supported: \(supported)"
        }
    }
}
