import Foundation
import FLDomain

/// The fixture/payload schema version rule for FLCommunityCore, mirroring
/// `FLSchema` in FLDomain but under this package's own namespace.
///
/// Every cross-language envelope produced here carries a top-level `"schema"`
/// string. Decoders accept `"flcommunity.v1"` and additive minor versions of
/// the form `"flcommunity.v1.<n>"` (a minor addition must remain readable by
/// every v1 decoder). Anything else — `flcommunity.v2`, an unknown prefix, a
/// typo — is refused, never reinterpreted. Bumping the major version is a
/// breaking change that requires shipping new decoders first.
public enum FLCommunitySchema {
    public static let acceptedMajor: String = "flcommunity.v1"

    public static func validate(_ raw: String) throws {
        if raw == acceptedMajor { return }
        let prefix = acceptedMajor + "."
        guard raw.hasPrefix(prefix), Int(raw.dropFirst(prefix.count)) != nil else {
            throw FLDomainError.unsupportedSchemaVersion(found: raw, supported: acceptedMajor)
        }
    }
}
