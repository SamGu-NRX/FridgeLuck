import Foundation

/// The reviewed substitution table loaded from `data/substitutions/pairs.json`.
///
/// Construct with `init(data:)` (or `init(json:)`). `loadDefault()` is an
/// in-repo convenience for tests and tooling that resolves the canonical
/// table relative to the package source location; standalone consumers embed
/// the JSON and construct from data.
public struct SubstitutionTable: Sendable {
    public let schemaVersion: String
    public let created: String
    public let roles: [Role]
    /// The shared Suite C contract classes the table's vocabulary is built on.
    public let sharedAllergenClasses: [AllergenClass]
    public let restrictionNames: [String]
    public let sources: [SourceRecord]
    public let ingredients: [String: IngredientRecord]
    public let pairs: [Pair]

    private let aliasToKey: [String: String]
    private let pairsByOriginal: [String: [Pair]]

    /// Decoding shape for the whole document.
    private struct Document: Codable {
        var schemaVersion: String
        var created: String
        var roles: [Role]
        var allergenClasses: [AllergenClass]
        var restrictions: [String: Restriction]
        var sources: [SourceRecord]
        var ingredients: [String: IngredientRecord]
        var pairs: [Pair]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case created
            case roles
            case allergenClasses = "allergen_classes"
            case restrictions
            case sources
            case ingredients
            case pairs
        }
    }

    public struct ValidationError: Error, CustomStringConvertible {
        public let problems: [String]

        public var description: String {
            "table validation failed (\(problems.count) problem\(problems.count == 1 ? "" : "s")):\n"
                + problems.map { "  - \($0)" }.joined(separator: "\n")
        }
    }

    /// Decode and validate. Fails loudly on any unknown enum value, dangling
    /// reference, missing citation, or alias collision.
    public init(data: Data) throws {
        let doc = try JSONDecoder().decode(Document.self, from: data)

        var problems: [String] = []
        let expectedRoles = Role.allCases.map(\.rawValue).sorted()
        if doc.roles.map(\.rawValue).sorted() != expectedRoles {
            problems.append("roles must cover exactly the 11 package roles")
        }
        let shared: Set<AllergenClass> = [.gluten, .dairy, .egg, .soy, .peanut, .treeNut, .sesame, .fish, .shellfish]
        if Set(doc.allergenClasses) != shared {
            problems.append("allergen_classes must be exactly the 9 shared Suite C contract classes")
        }
        if Set(doc.sources.map(\.id)).count != doc.sources.count {
            problems.append("duplicate source ids")
        }
        if Set(doc.pairs.map(\.id)).count != doc.pairs.count {
            problems.append("duplicate pair ids")
        }

        let sourceIDs = Set(doc.sources.map(\.id))
        for pair in doc.pairs {
            if pair.sourceIDs.isEmpty {
                problems.append("pair \(pair.id): no source citation")
            }
            for sid in pair.sourceIDs where !sourceIDs.contains(sid) {
                problems.append("pair \(pair.id): unknown source id \(sid)")
            }
            for key in [pair.original, pair.substitute] where doc.ingredients[key] == nil {
                problems.append("pair \(pair.id): unknown ingredient key \(key)")
            }
            if pair.difference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("pair \(pair.id): empty difference text")
            }
            if pair.preparation.isEmpty {
                problems.append("pair \(pair.id): empty preparation")
            }
            if !(pair.ratio.value.isFinite) || pair.ratio.value < 0 {
                problems.append("pair \(pair.id): ratio value must be finite and non-negative")
            }
            if pair.macroDelta == nil && (pair.macroDeltaNullReason ?? "").isEmpty {
                problems.append("pair \(pair.id): null macro delta needs macro_delta_null_reason")
            }
        }

        // Alias index with collision detection: an alias must resolve to one key.
        var aliasToKey: [String: String] = [:]
        for key in doc.ingredients.keys.sorted() {
            let record = doc.ingredients[key]!
            var names = [key, record.display]
            names.append(contentsOf: record.aliases)
            for name in names {
                let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                if let existing = aliasToKey[normalized], existing != key {
                    problems.append("alias collision: '\(normalized)' maps to both \(existing) and \(key)")
                } else {
                    aliasToKey[normalized] = key
                }
            }
        }

        if !problems.isEmpty {
            throw ValidationError(problems: problems.sorted())
        }

        self.schemaVersion = doc.schemaVersion
        self.created = doc.created
        self.roles = doc.roles
        self.sharedAllergenClasses = doc.allergenClasses.sorted { $0.rawValue < $1.rawValue }
        self.restrictionNames = doc.restrictions.keys.sorted()
        self.sources = doc.sources.sorted { $0.id < $1.id }
        self.ingredients = doc.ingredients
        self.pairs = doc.pairs
        self.aliasToKey = aliasToKey
        var byOriginal: [String: [Pair]] = [:]
        for pair in doc.pairs {
            byOriginal[pair.original, default: []].append(pair)
        }
        for key in byOriginal.keys {
            byOriginal[key]?.sort { $0.id < $1.id }
        }
        self.pairsByOriginal = byOriginal
        self.restrictions = doc.restrictions
    }

    public init(json: String) throws {
        try self.init(data: Data(json.utf8))
    }

    /// The named restrictions with their forbidden-class sets.
    public let restrictions: [String: Restriction]

    /// Resolve an ingredient by key, display name, or alias (case-insensitive).
    /// Throws rather than guessing: an unknown ingredient is a data error.
    public func resolveIngredientKey(_ name: String) throws -> String {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ingredients[name] != nil || ingredients[normalized] != nil {
            return ingredients[name] != nil ? name : normalized
        }
        guard let key = aliasToKey[normalized] else {
            throw SubstitutionError.unknownIngredient(name)
        }
        return key
    }

    public func ingredient(_ key: String) -> IngredientRecord? {
        ingredients[key]
    }

    /// Pairs whose original is the given ingredient key, sorted by pair id.
    public func pairs(forOriginal key: String) -> [Pair] {
        pairsByOriginal[key] ?? []
    }

    /// Locate the canonical in-repo table (`data/substitutions/pairs.json`)
    /// by walking up from this source file. Works for in-repo tests and
    /// tooling; standalone consumers load the JSON themselves.
    public static func loadDefault() throws -> SubstitutionTable {
        let here = URL(fileURLWithPath: #filePath)
        var dir = here.deletingLastPathComponent()
        for _ in 0...8 {
            let candidate = dir.appendingPathComponent("data/substitutions/pairs.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try SubstitutionTable(data: data)
            }
            let parent = dir.deletingLastPathComponent()
            guard parent != dir else { break }
            dir = parent
        }
        throw SubstitutionError.defaultTableNotFound
    }
}
