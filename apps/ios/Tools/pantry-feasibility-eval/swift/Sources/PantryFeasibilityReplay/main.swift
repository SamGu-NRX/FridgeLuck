import Foundation

// CLI: replay the frozen corpus through both predicates.
//
//   PantryFeasibilityReplay replay --corpus-dir <runs> --output <results.jsonl>
//   PantryFeasibilityReplay export-memberships
//
// `replay` evaluates every state against every catalog recipe under both the
// production predicate (ID-membership, as RecipeRepository.findMakeable does)
// and the data-model oracle, writing one JSON row per (state, recipe) pair.
// `export-memberships` dumps the vendored production allergen membership table
// as JSON so the Python harness can verify it stayed in sync with oracle.py.

struct ReplayRow: Codable {
    var state_id: Int
    var family: String
    var recipe_id: Int
    var production_makeable: Bool
    var oracle_feasible: Bool
    var oracle_infeasible_reasons: [String]
    var oracle_missing_required_ids: [Int64]
    var oracle_excluded_ids: [Int64]
    var oracle_tag_violation: Bool
    var oracle_unknown_quantity_assumptions: [Int64]
    var oracle_insufficient: [OracleVerdict.InsufficientRow]
}

func readJSONL<T: Decodable>(_ path: URL, as type: T.Type) throws -> [T] {
    let data = try Data(contentsOf: path)
    var rows: [T] = []
    var start = data.startIndex
    while start < data.endIndex {
        guard let newline = data[start...].firstIndex(of: UInt8(0x0A)) else { break }
        let lineData = data[start..<newline]
        start = data.index(after: newline)
        guard !lineData.isEmpty else { continue }
        rows.append(try JSONDecoder().decode(T.self, from: lineData))
    }
    return rows
}

func runReplay(corpusDir: URL, output: URL) throws {
    let snapshot = try JSONDecoder().decode(
        CatalogSnapshot.self,
        from: Data(contentsOf: corpusDir.appendingPathComponent("catalog_snapshot.json")))
    let states = try readJSONL(
        corpusDir.appendingPathComponent("states.jsonl"), as: EvalState.self)

    let recipes = snapshot.recipes.sorted { $0.recipeID < $1.recipeID }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    if !FileManager.default.createFile(atPath: output.path, contents: nil) {
        FileHandle.standardError.write(Data("cannot create \(output.path)\n".utf8))
        exit(1)
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }

    for state in states {
        for recipe in recipes {
            let production = ProductionPredicate.evaluate(state: state, recipe: recipe)
            let oracle = ReplayOracle.evaluate(state: state, recipe: recipe)
            let row = ReplayRow(
                state_id: state.state_id,
                family: state.family,
                recipe_id: recipe.recipeID,
                production_makeable: production.makeable,
                oracle_feasible: oracle.feasible,
                oracle_infeasible_reasons: oracle.infeasible_reasons,
                oracle_missing_required_ids: oracle.missing_required_ids,
                oracle_excluded_ids: oracle.excluded_ids,
                oracle_tag_violation: oracle.tag_violation,
                oracle_unknown_quantity_assumptions: oracle.unknown_quantity_assumptions,
                oracle_insufficient: oracle.insufficient)
            handle.write(try encoder.encode(row))
            handle.write(Data([UInt8(0x0A)]))
        }
    }

    FileHandle.standardError.write(
        Data("replayed \(states.count) states x \(recipes.count) recipes -> \(output.path)\n"
            .utf8))
}

struct ExportedMembership: Codable {
    var ingredient_id: Int64
    var bundled_name: String
    var groups: [String]
}

func exportMemberships() throws {
    let rows = AllergenExclusions.coreMemberships.map { membership in
        ExportedMembership(
            ingredient_id: membership.ingredientID,
            bundled_name: membership.bundledName,
            groups: membership.groups.map(\.rawValue).sorted())
    }.sorted { $0.ingredient_id < $1.ingredient_id }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(rows), as: UTF8.self))
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "replay":
    var corpusDir: URL?
    var output: URL?
    var iterator = args.dropFirst().makeIterator()
    while let flag = iterator.next() {
        switch flag {
        case "--corpus-dir": corpusDir = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--output": output = iterator.next().map { URL(fileURLWithPath: $0) }
        default:
            FileHandle.standardError.write(Data("unknown flag: \(flag)\n".utf8))
            exit(2)
        }
    }
    guard let corpus = corpusDir, let out = output else {
        FileHandle.standardError.write(
            Data("usage: replay --corpus-dir DIR --output FILE\n".utf8))
        exit(2)
    }
    try runReplay(corpusDir: corpus, output: out)
case "export-memberships":
    try exportMemberships()
default:
    FileHandle.standardError.write(
        Data("usage: PantryFeasibilityReplay <replay|export-memberships> [flags]\n".utf8))
    exit(2)
}
