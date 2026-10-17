import Crypto
import Foundation
import FLDomain

// MARK: - Payload hashing
// FLDomain's `ActionProposal.payloadHash` binds an approval to exactly what was
// shown (a 64-hex-lowercase SHA-256, format-validated by `FLHashFormat`).
// Computing that hash is this package's policy: the hash is the SHA-256 of the
// canonical payload bytes defined by `FLJSON` — the same bytes frozen in the
// cross-language fixtures. The TypeScript and Python sides reproduce the same
// bytes, so they can verify any hash we emit.

/// SHA-256 over the canonical `ActionPayload` encoding.
public enum FLPayloadHashing {
    /// The payload hash for `payload`: lowercase hex SHA-256 of the canonical
    /// JSON bytes (`FLJSON.canonicalData`). Always passes
    /// `FLHashFormat.validateSHA256Hex` by construction.
    public static func payloadHash(_ payload: ActionPayload) throws -> String {
        sha256Hex(try FLJSON.canonicalData(payload))
    }

    /// Lowercase hex SHA-256 of arbitrary bytes.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var hex = ""
        hex.reserveCapacity(2 * SHA256.byteCount)  // 32 bytes → 64 hex chars
        for byte in digest {
            // Two lowercase hex digits per byte, zero-padded — String(format:)
            // is avoided so the path has no printf dependency.
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return hex
    }

    private static let hexDigits = Array("0123456789abcdef")
}
