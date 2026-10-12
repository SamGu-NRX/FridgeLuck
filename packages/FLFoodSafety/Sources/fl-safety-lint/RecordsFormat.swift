import Foundation

/// The records file format `fl-safety-lint lint` consumes: a thin transport
/// shape over exactly what `BundledRecipeAudit` feeds the linters (recipe
/// title, ingredient list, newline-numbered instructions, per-step structured
/// safety fields) and what `CopyLint` scans (file · record id · field · text).
///
/// The CLI is a driver, not a linter: this file only decodes input and carries
/// it to the package linters, failing closed on any shape it does not
/// recognise (unknown keys, unknown kinds, unparsable step indices). The
/// format is documented in `data/food-safety/conformance/README.md`, which is
/// the single contract both this decoder and the test suite's decoder pin
/// against.
enum RecordsFormatError: Error, CustomStringConvertible {
    case format(String)

    var description: String {
        switch self {
        case .format(let message): return "records format error: \(message)"
        }
    }
}

/// One record to lint: a recipe (strict step linter) or a copy record (copy lint).
struct LintInputRecord: Sendable {
    enum Surface: Sendable {
        case recipe(title: String, ingredients: String, instructions: String, safetyFields: [Int: Data])
        case copy(field: String, text: String)
    }

    /// Synthetic source path reported in findings (fixtures carry no real data).
    let file: String
    /// The record's own id inside that file.
    let id: String
    let surface: Surface
}

enum RecordsFormat {
    static let schemaVersion = 1

    /// Decodes a whole records file: `{"schema_version": 1, "description": …,
    /// "records": [ … ]}`. Unknown top-level keys fail.
    static func decode(_ data: Data) throws -> [LintInputRecord] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RecordsFormatError.format("records file is not valid JSON: \(error)")
        }
        guard let doc = raw as? [String: Any] else {
            throw RecordsFormatError.format("records file top level must be an object")
        }
        try checkKeys(doc, allowed: ["schema_version", "description", "records"], what: "records file top level")
        guard (doc["schema_version"] as? Int) == schemaVersion else {
            throw RecordsFormatError.format("schema_version must be \(schemaVersion), found: \(doc["schema_version"] ?? "missing")")
        }
        guard let records = doc["records"] as? [Any] else {
            throw RecordsFormatError.format("records must be an array")
        }
        return try records.enumerated().map { index, item in
            try decodeRecord(item, what: "records[\(index)]")
        }
    }

    /// Decodes one record object. Recipe records carry `title`, `ingredients`,
    /// `instructions` and optional `safety_fields` (step index → structured
    /// safety field object, in the corpus shape `{"class", "temp_f", "method",
    /// "source"}`); copy records carry `field` and `text`.
    static func decodeRecord(_ raw: Any, what: String) throws -> LintInputRecord {
        guard let dict = raw as? [String: Any] else {
            throw RecordsFormatError.format("\(what) must be an object")
        }
        try checkKeys(dict, allowed: ["kind", "file", "id", "title", "ingredients", "instructions", "safety_fields", "field", "text"], what: what)
        guard let kind = dict["kind"] as? String else {
            throw RecordsFormatError.format("\(what): kind is missing (must be \"recipe\" or \"copy\")")
        }
        guard let file = dict["file"] as? String, !file.isEmpty else {
            throw RecordsFormatError.format("\(what): file is missing or empty")
        }
        guard let id = dict["id"] as? String, !id.isEmpty else {
            throw RecordsFormatError.format("\(what): id is missing or empty")
        }

        switch kind {
        case "recipe":
            try checkKeys(dict, allowed: ["kind", "file", "id", "title", "ingredients", "instructions", "safety_fields"], what: "\(what) (recipe)")
            guard let instructions = dict["instructions"] as? String, !instructions.isEmpty else {
                throw RecordsFormatError.format("\(what): instructions is missing or empty")
            }
            let safetyFields = try decodeSafetyFields(dict["safety_fields"], what: what)
            return LintInputRecord(
                file: file, id: id,
                surface: .recipe(
                    title: dict["title"] as? String ?? "",
                    ingredients: dict["ingredients"] as? String ?? "",
                    instructions: instructions,
                    safetyFields: safetyFields
                )
            )
        case "copy":
            try checkKeys(dict, allowed: ["kind", "file", "id", "field", "text"], what: "\(what) (copy)")
            guard let field = dict["field"] as? String, !field.isEmpty else {
                throw RecordsFormatError.format("\(what): field is missing or empty")
            }
            guard let text = dict["text"] as? String, !text.isEmpty else {
                throw RecordsFormatError.format("\(what): text is missing or empty")
            }
            return LintInputRecord(file: file, id: id, surface: .copy(field: field, text: text))
        default:
            throw RecordsFormatError.format("\(what): unknown kind '\(kind)' (must be \"recipe\" or \"copy\")")
        }
    }

    /// `safety_fields` maps a zero-based step index to the record's structured
    /// safety field object. Any JSON object is accepted — an unparseable or
    /// understated field is a linter finding (clause 7 / clause 5), not a
    /// driver error — but the keys must be step indices and the values objects.
    static func decodeSafetyFields(_ raw: Any?, what: String) throws -> [Int: Data] {
        guard let raw else { return [:] }
        guard let dict = raw as? [String: Any] else {
            throw RecordsFormatError.format("\(what): safety_fields must be an object mapping step indices to safety-field objects")
        }
        var fields: [Int: Data] = [:]
        for (key, value) in dict {
            guard let index = Int(key), index >= 0 else {
                throw RecordsFormatError.format("\(what): safety_fields key '\(key)' is not a zero-based step index")
            }
            guard value is [String: Any] else {
                throw RecordsFormatError.format("\(what): safety_fields['\(key)'] must be an object")
            }
            fields[index] = try JSONSerialization.data(withJSONObject: value)
        }
        return fields
    }

    static func checkKeys(_ dict: [String: Any], allowed: Set<String>, what: String) throws {
        let unknown = Set(dict.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw RecordsFormatError.format("\(what): unknown key(s) \(unknown.sorted().joined(separator: ", "))")
        }
    }
}
