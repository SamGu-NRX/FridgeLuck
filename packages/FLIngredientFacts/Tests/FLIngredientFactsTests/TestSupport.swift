import Foundation
@testable import FLIngredientFacts

enum DatasetLocator {
    /// The bundled dataset lives at <repo-root>/data/ingredient-facts; tests
    /// resolve it from the compile-time source path (Tests/FLIngredientFactsTests).
    static func datasetDirectory() -> URL {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return here
            .appendingPathComponent("../../../..")
            .appendingPathComponent("data/ingredient-facts")
    }

    static func casesFile() -> URL {
        datasetDirectory().appendingPathComponent("conformance/cases.json")
    }
}

enum DatasetMutation {
    /// Writes a mutated copy of the dataset into a temporary directory and
    /// hands back the directory URL. The mutation receives the mutable JSON
    /// containers for identities.json and facts.json.
    static func withMutatedCopy(
        _ mutate: (inout JSON, inout JSON) throws -> Void
    ) throws -> URL {
        let source = DatasetLocator.datasetDirectory()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("flfacts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("conformance"), withIntermediateDirectories: true)

        var identities = try JSON(parse: try Data(contentsOf: source.appendingPathComponent("identities.json")))
        var facts = try JSON(parse: try Data(contentsOf: source.appendingPathComponent("facts.json")))
        try mutate(&identities, &facts)
        try JSON.write(identities, to: target.appendingPathComponent("identities.json"))
        try JSON.write(facts, to: target.appendingPathComponent("facts.json"))
        return target
    }
}

/// Minimal mutable JSON wrapper so mutations read declaratively.
struct JSON {
    var value: Any

    init(parse: Data) throws {
        value = try JSONSerialization.jsonObject(with: parse, options: [.fragmentsAllowed])
    }

    static func write(_ json: JSON, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json.value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Traverses arrays/dictionaries by index or key, forcing mutability.
    subscript(path: Any...) -> Any {
        get { Self.get(value, path: path) }
        set { Self.set(newValue, at: &value, path: path) }
    }

    private static func get(_ node: Any, path: [Any]) -> Any {
        var node = node
        for key in path {
            if let index = key as? Int {
                node = (node as! [Any])[index]
            } else {
                let dict = node as! [String: Any]
                guard let next = dict[key as! String] else {
                    fatalError("JSON.get: missing key '\(key)' in path \(path)")
                }
                node = next
            }
        }
        return node
    }

    private static func set(_ newValue: Any, at node: inout Any, path: [Any]) {
        guard let key = path.first else { node = newValue; return }
        if let index = key as? Int {
            var array = node as! [Any]
            var element = array[index]
            set(newValue, at: &element, path: Array(path.dropFirst()))
            array[index] = element
            node = array
        } else {
            let name = key as! String
            var dict = node as! [String: Any]
            // Absent keys are created: mutations may insert new entries.
            var element = dict[name] ?? NSNull()
            set(newValue, at: &element, path: Array(path.dropFirst()))
            dict[name] = element
            node = dict
        }
    }
}
