import Foundation
import FLDomain

// MARK: - Recipe sharing: the payload that leaves the phone
// SPEC 3.4: publishing a recipe is a separate, previewed action; the author
// declares the recipe is their own or that they have the right to share it.
// SPEC 3.5: ship only recipes the app has the right to ship; unknown rights
// means quarantine. The payload type below is constructible only from a
// revision that passes that policy, so an existing `RecipeSharePayload` value
// is always shareable. Import is a total function over untrusted bytes and
// therefore returns decisions, not exceptions (see `RecipeImportPolicy`).

/// The author's rights declaration that travels with every shared revision
/// (SPEC 3.4). Sharing always carries it: the payload must state on its face
/// that the sharer owns the work or has the right to share it.
public struct RecipeRightsDeclaration: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// "This recipe is my own work."
        case ownWork
        /// "This is not my own work, but I have the right to share it."
        case haveRightsToShare
    }

    /// The declaration kind. Raw values are part of the cross-language contract.
    public let kind: Kind
    /// The declaration as recorded, e.g. "original recipe written by me" or
    /// "shared with the license stated in the recipe's rights evidence".
    /// Never empty.
    public let statement: String
    /// When the declaration was made (canonical UTC timestamp on the wire).
    public let declaredAt: Date

    public init(kind: Kind, statement: String, declaredAt: Date) throws {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "RecipeRightsDeclaration.statement", reason: "must not be empty; a rights declaration without a statement is not evidence")
        }
        guard trimmed.count <= 2000 else {
            throw FLDomainError.validation(target: "RecipeRightsDeclaration.statement", reason: "must be at most 2000 characters")
        }
        self.kind = kind
        self.statement = trimmed
        self.declaredAt = declaredAt
    }
}

extension RecipeRightsDeclaration: Codable {
    private enum CodingKeys: String, CodingKey { case kind, statement, declaredAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            statement: try container.decode(String.self, forKey: .statement),
            declaredAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .declaredAt),
                target: "RecipeRightsDeclaration.declaredAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(statement, forKey: .statement)
        try container.encode(FLTimestamp.encode(declaredAt), forKey: .declaredAt)
    }
}

/// The exact unit that leaves the phone when a recipe is shared: the full
/// structured revision with its license evidence preserved (attribution,
/// grants, evidence string), plus the sharer's rights declaration.
///
/// Evidence-chain rule: the revision is embedded as-is. Export never rewrites
/// the key, the attribution or any grant, so `export → bytes → import`
/// reproduces the revision byte for byte (frozen in `Fixtures/`).
public struct RecipeSharePayload: Hashable, Sendable {
    /// The schema string this payload always carries on the wire.
    public static let schemaValue: String = FLCommunitySchema.acceptedMajor

    public let schema: String
    public let revision: RecipeRevision
    /// The sharer's rights declaration. Always set on export; nil only when
    /// decoded from a foreign payload that omitted it — a policy refusal on
    /// import (SPEC 3.4: sharing always carries the declaration), not a
    /// decode error, so the preview can say exactly what is missing.
    public let declaration: RecipeRightsDeclaration?
    public let sharedAt: Date

    /// Export: build a shareable payload from a local revision.
    ///
    /// Refuses (throws) any revision the app does not have the right to ship:
    /// - a LeChef draft (private by definition, SPEC 3.5; promotion goes
    ///   through the review path, not sharing);
    /// - a quarantined revision (unknown rights on text, modification or
    ///   offline use, and — mirroring the tightened FLDomain rights rule of
    ///   2026-10-11 — unknown or forbidden caching: caching must be
    ///   explicitly `.permitted`);
    /// - a revision whose text or offline-use right is explicitly forbidden;
    /// - a revision whose license requires attribution that the revision
    ///   does not carry (review round 2: the export gate fails closed on
    ///   missing required attribution, whitespace included).
    /// The declaration is mandatory: sharing always carries it (SPEC 3.4).
    public init(revision: RecipeRevision, declaration: RecipeRightsDeclaration, sharedAt: Date) throws {
        // One export gate for both payload types that embed revision text —
        // this one and SharedCook. Its rights checks byte-match the inline
        // checks this init used before review round 2; the gate adds the
        // required-attribution rule so no export path can skip it.
        try RecipeExportGate.validateExportable(revision, target: "RecipeSharePayload.revision")
        self = RecipeSharePayload(checkedRevision: revision, declaration: declaration, sharedAt: sharedAt)
    }

    /// Field assignment without the export policy. Decoding uses this path:
    /// a payload may come from anyone, and it is `RecipeImportPolicy`'s job
    /// to classify it (accepted / quarantined / refused), not the decoder's.
    /// Internal (not private) so tests can hand-build payloads a non-policy
    /// sender's app might produce.
    init(checkedRevision revision: RecipeRevision, declaration: RecipeRightsDeclaration?, sharedAt: Date) {
        self.schema = Self.schemaValue
        self.revision = revision
        self.declaration = declaration
        self.sharedAt = sharedAt
    }

    /// Canonical JSON bytes of this payload — the exact bytes that leave the
    /// phone and the form frozen in `Fixtures/recipe-share-payload.json`.
    public func canonicalData() throws -> Data {
        try FLJSON.canonicalData(self)
    }
}

extension RecipeSharePayload: Codable {
    private enum CodingKeys: String, CodingKey { case schema, revision, declaration, sharedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        try FLCommunitySchema.validate(schema)
        // Deliberately the unchecked path: see its doc comment.
        self = RecipeSharePayload(
            checkedRevision: try container.decode(RecipeRevision.self, forKey: .revision),
            declaration: try container.decodeIfPresent(RecipeRightsDeclaration.self, forKey: .declaration),
            sharedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .sharedAt),
                target: "RecipeSharePayload.sharedAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(declaration, forKey: .declaration)
        try container.encode(FLTimestamp.encode(sharedAt), forKey: .sharedAt)
    }
}
