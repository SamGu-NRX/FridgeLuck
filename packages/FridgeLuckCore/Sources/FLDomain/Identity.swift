import Foundation

// MARK: - Recipe identity

/// Where a recipe came from. The raw values are part of the cross-language
/// fixture contract; they are stable identifiers, not display strings.
public enum RecipeSource: String, Codable, Sendable, CaseIterable {
    /// The bundled, rights-reviewed catalog.
    case catalog
    /// Authored on this device; private by default (SPEC 3.4, 3.5).
    case user
    /// Published by another account and fetched from the community service.
    case community
    /// Imported text from someone else's website; cannot be published unless
    /// the author declares the right to share it (SPEC 3.5).
    case imported
    /// A LeChef-generated private draft ("Made for your fridge").
    case lechef
}

/// The stable external identity of one revision of one recipe.
///
/// Deliberately distinct from the local `Int64` row IDs in SQLite: rows are
/// rebuildable artifacts of one device's database, while this key survives
/// reinstalls, sync and community sharing. A revision number increments when
/// the recipe content changes; two revisions with the same source and id are
/// different revisions.
public struct RecipeKey: Hashable, Sendable {
    public let source: RecipeSource
    public let sourceRecipeID: String
    public let revision: Int

    public init(source: RecipeSource, sourceRecipeID: String, revision: Int) throws {
        let trimmedID = sourceRecipeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw FLDomainError.validation(target: "RecipeKey.sourceRecipeID", reason: "must not be empty")
        }
        guard trimmedID.count <= 256 else {
            throw FLDomainError.validation(target: "RecipeKey.sourceRecipeID", reason: "must be at most 256 characters")
        }
        guard revision >= 1 else {
            throw FLDomainError.validation(target: "RecipeKey.revision", reason: "must be >= 1 (got \(revision))")
        }
        self.source = source
        self.sourceRecipeID = trimmedID
        self.revision = revision
    }
}

extension RecipeKey: CustomStringConvertible {
    public var description: String {
        "\(source.rawValue):\(sourceRecipeID)@r\(revision)"
    }
}

extension RecipeKey: Codable {
    private enum CodingKeys: String, CodingKey { case source, sourceRecipeID, revision }

    /// Decoding runs the same validation as construction, so a bad fixture or
    /// payload is rejected at the boundary, not later at use.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: try container.decode(RecipeSource.self, forKey: .source),
            sourceRecipeID: try container.decode(String.self, forKey: .sourceRecipeID),
            revision: try container.decode(Int.self, forKey: .revision)
        )
    }
}

// MARK: - Ingredient identity

/// USDA FoodData Central identity for an ingredient, distinct from any local
/// ingredient row ID (engineering plan, Goal 4: a resolver must not remap FDC
/// identity onto local IDs).
public struct FDCIngredientKey: Hashable, Sendable {
    /// A positive FDC ID as assigned by USDA FoodData Central.
    public let fdcID: Int

    public init(fdcID: Int) throws {
        guard fdcID > 0 else {
            throw FLDomainError.validation(target: "FDCIngredientKey.fdcID", reason: "must be positive (got \(fdcID))")
        }
        self.fdcID = fdcID
    }
}

extension FDCIngredientKey: Codable {
    private enum CodingKeys: String, CodingKey { case fdcID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fdcID: try container.decode(Int.self, forKey: .fdcID))
    }
}

/// Ingredient identity on one recipe line: canonical name plus whichever
/// identities are known. An unresolved line has neither FDC nor local identity
/// and is preserved as-is — unresolved lines block complete feasibility and
/// complete nutrition claims, they are never dropped (engineering plan, Goal 4).
public struct IngredientReference: Hashable, Sendable {
    /// USDA identity when the line is resolved.
    public let fdc: FDCIngredientKey?
    /// Local ingredient row ID when a mapping exists. Never conflated with `fdc`.
    public let localIngredientID: Int64?
    /// Canonical, validated name (e.g. "whole milk"). Never empty.
    public let canonicalName: String
    /// Version of the resolver that produced this reference, when resolved.
    public let resolverVersion: Int?

    public init(
        fdc: FDCIngredientKey? = nil,
        localIngredientID: Int64? = nil,
        canonicalName: String,
        resolverVersion: Int? = nil
    ) throws {
        let trimmed = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "IngredientReference.canonicalName", reason: "must not be empty")
        }
        guard trimmed.count <= 256 else {
            throw FLDomainError.validation(target: "IngredientReference.canonicalName", reason: "must be at most 256 characters")
        }
        if let resolverVersion {
            guard resolverVersion >= 1 else {
                throw FLDomainError.validation(target: "IngredientReference.resolverVersion", reason: "must be >= 1 (got \(resolverVersion))")
            }
        }
        self.fdc = fdc
        self.localIngredientID = localIngredientID
        self.canonicalName = trimmed
        self.resolverVersion = resolverVersion
    }
}

extension IngredientReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case fdc, localIngredientID, canonicalName, resolverVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fdc: try container.decodeIfPresent(FDCIngredientKey.self, forKey: .fdc),
            localIngredientID: try container.decodeIfPresent(Int64.self, forKey: .localIngredientID),
            canonicalName: try container.decode(String.self, forKey: .canonicalName),
            resolverVersion: try container.decodeIfPresent(Int.self, forKey: .resolverVersion)
        )
    }
}

// MARK: - Versioned identity mapping

/// A versioned mapping between stable external keys and local `Int64` row IDs.
///
/// The schema version travels with the mapping: a build that finds a mapping
/// whose major schema it does not know refuses it instead of guessing. Entries
/// are unique on both sides — one key maps to one row, one row to one key.
public struct RecipeIdentityMapping: Hashable, Sendable {
    /// The only major schema version this build accepts.
    public static let supportedSchemaVersion: Int = 1

    public struct Entry: Hashable, Sendable {
        public let key: RecipeKey
        /// Local SQLite rowid. Positive: SQLite rowids start at 1.
        public let localRowID: Int64

        public init(key: RecipeKey, localRowID: Int64) throws {
            guard localRowID > 0 else {
                throw FLDomainError.validation(target: "RecipeIdentityMapping.Entry.localRowID", reason: "must be positive (got \(localRowID))")
            }
            self.key = key
            self.localRowID = localRowID
        }
    }

    public let schemaVersion: Int
    public let entries: [Entry]

    public init(schemaVersion: Int, entries: [Entry]) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw FLDomainError.unsupportedSchemaVersion(
                found: "mapping.schemaVersion=\(schemaVersion)",
                supported: "mapping.schemaVersion=\(Self.supportedSchemaVersion)"
            )
        }
        // Uniqueness on both sides of the mapping.
        let keys = entries.map(\.key)
        guard Set(keys).count == keys.count else {
            throw FLDomainError.validation(target: "RecipeIdentityMapping.entries", reason: "duplicate RecipeKey in mapping")
        }
        let rowIDs = entries.map(\.localRowID)
        guard Set(rowIDs).count == rowIDs.count else {
            throw FLDomainError.validation(target: "RecipeIdentityMapping.entries", reason: "duplicate localRowID in mapping")
        }
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public func localRowID(for key: RecipeKey) -> Int64? {
        entries.first(where: { $0.key == key })?.localRowID
    }

    public func key(forLocalRowID rowID: Int64) -> RecipeKey? {
        entries.first(where: { $0.localRowID == rowID })?.key
    }
}

extension RecipeIdentityMapping: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            entries: try container.decode([Entry].self, forKey: .entries)
        )
    }
}

extension RecipeIdentityMapping.Entry: Codable {
    private enum CodingKeys: String, CodingKey { case key, localRowID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: try container.decode(RecipeKey.self, forKey: .key),
            localRowID: try container.decode(Int64.self, forKey: .localRowID)
        )
    }
}
