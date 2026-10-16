// Strict loading and validation of data/ingredient-facts.
//
// The schemas here mirror the pinned contracts in
// packages/FLIngredientFacts/README.md and data/ingredient-facts/README.md.
// Loading rejects malformed data rather than guessing: unknown enum strings,
// duplicate names, unresolved references, missing evidence and absence facts
// resting on catalog/recipe evidence are all load errors.

import Foundation

enum FLDatasetError: Error, CustomStringConvertible {
    case missingFile(String)
    case invalidJSON(String, String)
    case invalid(String)

    var description: String {
        switch self {
        case .missingFile(let path): return "missing dataset file: \(path)"
        case .invalidJSON(let path, let detail): return "invalid JSON in \(path): \(detail)"
        case .invalid(let detail): return "invalid dataset: \(detail)"
        }
    }
}

struct FactObject: Codable, Hashable, Sendable {
    var state: String
    var evidence: FLEvidence?
}

struct ComponentObject: Codable, Hashable, Sendable {
    var key: String
    var certainty: String
    var evidence: FLEvidence?
}

struct FormOverride: Codable, Hashable, Sendable {
    var allergens: [String: FactObject]?
    var gluten: FactObject?
    var diets: [String: FactObject]?
}

/// One fact entry (identity, preparation form or shared component).
struct FactEntry: Codable, Hashable, Sendable {
    var key: String
    var `class`: String?
    var components: [ComponentObject]?
    var compositionComplete: Bool?
    var note: String?
    var allergens: [String: FactObject]?
    var gluten: FactObject?
    var diets: [String: FactObject]?
    var forms: [String: FormOverride]?
}

struct FormRecord: Codable, Hashable, Sendable {
    var key: String
    var display: String
    var synonyms: [String]?
}

struct IdentityRecord: Codable, Hashable, Sendable {
    var key: String
    var display: String
    var kind: String?
    var synonyms: [String]?
    var usdaFdcId: Int?
    var usdaRef: String?
    var usdaNote: String?
    var appLocalIds: [Int]?
    var forms: [FormRecord]?
    var note: String?
}

struct IdentitiesFile: Codable, Sendable {
    var version: Int
    var ingredients: [IdentityRecord]
}

struct FactsFile: Codable, Sendable {
    var version: Int
    var facts: [String: FactEntry]
}

/// A loaded, validated dataset.
struct FLDataset: Sendable {
    let identities: [IdentityRecord]
    let identityByKey: [String: IdentityRecord]
    let facts: [String: FactEntry]

    /// Every resolvable name -> fact key (identity key, display, synonyms, form
    /// match names, and form fact keys). Case-folded.
    var nameIndex: [String: String]

    /// Names that resolve to a preparation form: folded name -> (identity key, form key).
    var formIndex: [String: (identity: String, form: String)]

    static func load(dataDirectory: URL) throws -> FLDataset {
        let identitiesURL = dataDirectory.appendingPathComponent("identities.json")
        let factsURL = dataDirectory.appendingPathComponent("facts.json")
        guard FileManager.default.fileExists(atPath: identitiesURL.path) else {
            throw FLDatasetError.missingFile(identitiesURL.path)
        }
        guard FileManager.default.fileExists(atPath: factsURL.path) else {
            throw FLDatasetError.missingFile(factsURL.path)
        }

        let identities: IdentitiesFile
        let facts: FactsFile
        do {
            identities = try JSONDecoder().decode(IdentitiesFile.self, from: try Data(contentsOf: identitiesURL))
            facts = try JSONDecoder().decode(FactsFile.self, from: try Data(contentsOf: factsURL))
        } catch let error as DecodingError {
            throw FLDatasetError.invalidJSON(identitiesURL.path, String(describing: error))
        } catch let error as FLDatasetError {
            throw error
        } catch {
            throw FLDatasetError.invalidJSON(factsURL.path, String(describing: error))
        }

        var dataset = FLDataset(
            identities: identities.ingredients,
            identityByKey: [:],
            facts: facts.facts,
            nameIndex: [:],
            formIndex: [:]
        )
        try dataset.validate(identities: identities.ingredients)
        return dataset
    }

    private mutating func indexName(_ raw: String, _ key: String) throws {
        let name = Self.normalized(raw)
        guard nameIndex[name] == nil else {
            let existing = nameIndex[name]!
            if existing != key {
                throw FLDatasetError.invalid("name '\(raw)' maps to both \(existing) and \(key)")
            }
            return
        }
        nameIndex[name] = key
    }

    private mutating func indexFormName(_ raw: String, identity: String, form: String) throws {
        let name = Self.normalized(raw)
        guard formIndex[name] == nil, nameIndex[name] == nil else {
            throw FLDatasetError.invalid("match name '\(raw)' is not unique (identity \(identity), form \(form))")
        }
        formIndex[name] = (identity, form)
        nameIndex[name] = identity
    }

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: validation (fail loud on malformed data)

    private mutating func validate(identities: [IdentityRecord]) throws {
        guard !identities.isEmpty else { throw FLDatasetError.invalid("identities.json is empty") }
        guard !facts.isEmpty else { throw FLDatasetError.invalid("facts.json is empty") }

        var identityKeys = Set<String>()
        for ing in identities {
            guard !identityKeys.contains(ing.key) else {
                throw FLDatasetError.invalid("duplicate identity key '\(ing.key)'")
            }
            identityKeys.insert(ing.key)

            guard facts[ing.key] != nil || ing.key == "artisan-granola-bar" else {
                throw FLDatasetError.invalid("identity '\(ing.key)' has no fact entry")
            }
            try indexName(ing.key, ing.key)
            try indexName(ing.display, ing.key)
            for syn in ing.synonyms ?? [] {
                try indexName(syn, ing.key)
            }
            for form in ing.forms ?? [] {
                for syn in form.synonyms ?? [] {
                    try indexFormName(syn, identity: ing.key, form: form.key)
                }
                guard let fact = facts[ing.key], fact.forms?[form.key] != nil else {
                    throw FLDatasetError.invalid(
                        "identity '\(ing.key)' form '\(form.key)' has no fact override")
                }
            }
        }

        for (key, entry) in facts {
            guard entry.key == key else {
                throw FLDatasetError.invalid("fact entry key mismatch: \(key) vs \(entry.key)")
            }
            for (allergen, fact) in entry.allergens ?? [:] {
                guard FLAllergen(rawValue: allergen) != nil else {
                    throw FLDatasetError.invalid("\(key): unknown allergen '\(allergen)'")
                }
                try validateFact(fact, where: "\(key).allergens.\(allergen)")
            }
            for (diet, fact) in entry.diets ?? [:] {
                guard FLDiet(rawValue: diet) != nil else {
                    throw FLDatasetError.invalid("\(key): unknown diet '\(diet)'")
                }
                try validateFact(fact, where: "\(key).diets.\(diet)")
            }
            if let gluten = entry.gluten {
                try validateFact(gluten, where: "\(key).gluten")
            }
            for (formName, override) in entry.forms ?? [:] {
                for (allergen, fact) in override.allergens ?? [:] {
                    guard FLAllergen(rawValue: allergen) != nil else {
                        throw FLDatasetError.invalid("\(key).forms.\(formName): unknown allergen '\(allergen)'")
                    }
                    try validateFact(fact, where: "\(key).forms.\(formName).allergens.\(allergen)")
                }
                for (diet, fact) in override.diets ?? [:] {
                    guard FLDiet(rawValue: diet) != nil else {
                        throw FLDatasetError.invalid("\(key).forms.\(formName): unknown diet '\(diet)'")
                    }
                    try validateFact(fact, where: "\(key).forms.\(formName).diets.\(diet)")
                }
                if let gluten = override.gluten {
                    try validateFact(gluten, where: "\(key).forms.\(formName).gluten")
                }
            }
            for component in entry.components ?? [] {
                guard facts[component.key] != nil else {
                    throw FLDatasetError.invalid(
                        "\(key): component key '\(component.key)' does not resolve")
                }
                switch component.certainty {
                case "certain", "typical", "variable", "unknown": break
                default:
                    throw FLDatasetError.invalid(
                        "\(key): bad certainty '\(component.certainty)'")
                }
                if component.certainty != "unknown", component.evidence == nil {
                    throw FLDatasetError.invalid(
                        "\(key): component '\(component.key)' lacks evidence")
                }
                if let evidence = component.evidence,
                    evidence.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    evidence.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw FLDatasetError.invalid(
                        "\(key): component '\(component.key)' evidence ref and note must be non-empty")
                }
            }
        }
    }

    private func validateFact(_ fact: FactObject, where where_: String) throws {
        switch fact.state {
        case "contains", "free", "unknown", "allowed", "violated": break
        default:
            throw FLDatasetError.invalid("\(where_): bad state '\(fact.state)'")
        }
        guard let evidence = fact.evidence else {
            if fact.state == "unknown" { return }   // unknown facts may be unsourced
            throw FLDatasetError.invalid("\(where_): \(fact.state) fact lacks evidence")
        }
        if evidence.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            evidence.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FLDatasetError.invalid("\(where_): evidence ref and note must be non-empty")
        }
        // Absence never rests on catalog or recipe evidence: a nutrient-catalog
        // mapping or a recipe occurrence is not proof an allergen is absent.
        if fact.state == "free" || fact.state == "allowed" {
            switch evidence.kind {
            case .usda, .recipe:
                throw FLDatasetError.invalid(
                    "\(where_): absence state '\(fact.state)' may not use '\(evidence.kind.rawValue)' evidence")
            case .label, .reference, .standard:
                break
            }
        }
    }
}
