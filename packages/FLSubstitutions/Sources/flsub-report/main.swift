import Foundation
import FLSubstitutions

// Deterministic coverage report over the bundled recipes.
//
// Usage:
//   flsub-report --table <pairs.json> --recipes <data.json>
//
// Emits REPORT.md on stdout. Deterministic: no timestamps, all dictionary
// iteration sorted; two runs are byte-identical.

struct UsageError: Error, CustomStringConvertible {
    var description: String { "usage: flsub-report --table <pairs.json> --recipes <data.json>" }
}

func parseArgs() throws -> (table: String, recipes: String) {
    var args = Array(CommandLine.arguments.dropFirst())
    var table: String?
    var recipes: String?
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--table":
            guard !args.isEmpty else { throw UsageError() }
            table = args.removeFirst()
        case "--recipes":
            guard !args.isEmpty else { throw UsageError() }
            recipes = args.removeFirst()
        default:
            throw UsageError()
        }
    }
    guard let tablePath = table, let recipesPath = recipes else { throw UsageError() }
    return (tablePath, recipesPath)
}

// MARK: - data.json reading (positional arrays, JSONSerialization)

struct RecipeLines {
    var title: String
    /// (app ingredient id, source list: 0 = required, 1 = optional)
    var refs: [(id: String, list: Int)]
}

func loadRecipes(path: String) throws -> (names: [String: String], lines: [RecipeLines]) {
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
    guard let root = raw as? [String: Any],
          let ingDict = root["ingredients"] as? [String: [Any]],
          let recipeList = root["recipes"] as? [[Any]]
    else { throw UsageError() }

    var names: [String: String] = [:]
    for (id, fields) in ingDict.sorted(by: { $0.key < $1.key }) {
        if let name = fields.first as? String { names[id] = name }
    }

    var lines: [RecipeLines] = []
    for recipe in recipeList {
        let title = (recipe.count > 1 ? recipe[1] as? String : nil) ?? "untitled"
        var refs: [(String, Int)] = []
        // Position 4 holds required ingredient refs, position 5 optional ones;
        // each ref is [ingredient_id, grams].
        for (listIndex, position) in [(0, 4), (1, 5)] {
            guard recipe.count > position, let refList = recipe[position] as? [[Any]] else { continue }
            for ref in refList {
                guard let id = ref.first as? Int else { continue }
                refs.append((String(id), listIndex))
            }
        }
        lines.append(RecipeLines(title: title, refs: refs))
    }
    return (names, lines)
}

// MARK: - Report body

func main() throws {
    let paths = try parseArgs()
    let tableData = try Data(contentsOf: URL(fileURLWithPath: paths.table))
    let table = try SubstitutionTable(data: tableData)
    let corpus = try loadRecipes(path: paths.recipes)

    var out: [String] = []
    func emit(_ line: String) { out.append(line) }

    emit("# Substitution coverage report")
    emit("")
    emit("Regenerated deterministically by the `flsub-report` executable in")
    emit("`packages/FLSubstitutions` from the committed table and the bundled recipe data.")
    emit("Regenerate from the repository root:")
    emit("")
    emit("    swift run -c release --package-path packages/FLSubstitutions flsub-report \\")
    emit("      --table data/substitutions/pairs.json \\")
    emit("      --recipes apps/ios/Resources/data.json \\")
    emit("      > data/substitutions/REPORT.md")
    emit("")
    emit("Two runs are byte-identical. A line counts as covered when its ingredient")
    emit("has at least one `verified` swap (sourced function and ratio evidence,")
    emit("PR #49 semantics) for any of the pair's connected roles, and the swap is")
    emit("not refused for the listed restrictions. The bundled recipes do not encode")
    emit("a functional role per line, so per-role fit is decided at lookup time by")
    emit("`ContextRules` — a covered line means the table has verified support for")
    emit("the ingredient, not that every use of it is verified.")
    emit("")

    // Map every app ingredient name to a table identity.
    var appToKey: [String: String] = [:]
    var unmapped: Set<String> = []
    for (id, appName) in corpus.names.sorted(by: { $0.key < $1.key }) {
        if let key = try? table.resolveIngredientKey(appName) {
            appToKey[id] = key
        } else if let key = try? table.resolveIngredientKey(appName.replacingOccurrences(of: "_", with: " ")) {
            appToKey[id] = key
        } else {
            unmapped.insert(appName)
        }
    }

    // Verified keys, unrestricted and per restriction.
    let distinctKeys = Array(Set(appToKey.values)).sorted()
    func verifiedKeysUnder(restrictions: [String]) -> Set<String> {
        var ok: Set<String> = []
        for key in distinctKeys {
            let display = table.ingredient(key)?.display ?? key
            if let swaps = try? table.verifiedSwaps(for: display, restrictions: restrictions),
               !swaps.isEmpty {
                ok.insert(key)
            }
        }
        return ok
    }
    let verifiedUnrestricted = verifiedKeysUnder(restrictions: [])
    let perRestriction: [(name: String, keys: Set<String>)] =
        table.restrictionNames.sorted().map { ($0, verifiedKeysUnder(restrictions: [$0])) }

    // Line-level coverage.
    var lineCount = 0
    var coveredUnrestricted = 0
    var coveredPerRestriction: [(name: String, count: Int)] = perRestriction.map { ($0.name, 0) }
    var gapLineCounts: [String: Int] = [:]
    for recipe in corpus.lines {
        for ref in recipe.refs {
            lineCount += 1
            guard let key = appToKey[ref.id] else {
                if let appName = corpus.names[ref.id] { gapLineCounts[appName, default: 0] += 1 }
                continue
            }
            if verifiedUnrestricted.contains(key) {
                coveredUnrestricted += 1
            } else {
                if let appName = corpus.names[ref.id] { gapLineCounts[appName, default: 0] += 1 }
            }
            for (index, restricted) in perRestriction.enumerated() where restricted.keys.contains(key) {
                coveredPerRestriction[index].count += 1
            }
        }
    }

    let distinctAppIngredients = corpus.names.count
    emit("## Corpus")
    emit("")
    emit("- Recipes: \(corpus.lines.count)")
    emit("- Ingredient lines (required + optional): \(lineCount)")
    emit("- Distinct app ingredients referenced: \(distinctAppIngredients)")
    emit("- App ingredients with no table identity: \(unmapped.count)\(unmapped.isEmpty ? "" : " — " + unmapped.sorted().joined(separator: ", "))")
    emit("- Table: \(table.pairs.count) pairs, \(table.ingredients.count) ingredients, \(table.sources.count) sources")
    emit("")

    emit("## Verified-swap coverage")
    emit("")
    emit("| Eater scope | Lines covered | Share |")
    emit("| --- | --- | --- |")
    func share(_ n: Int) -> String {
        guard lineCount > 0 else { return "n/a" }
        return String(format: "%.1f%%", Double(n) * 100.0 / Double(lineCount))
    }
    emit("| No restrictions | \(coveredUnrestricted) | \(share(coveredUnrestricted)) |")
    for row in coveredPerRestriction {
        emit("| \(row.name) | \(row.count) | \(share(row.count)) |")
    }
    emit("")

    emit("## Most common gaps")
    emit("")
    emit("App ingredients whose lines have no verified swap (no restrictions),")
    emit("ranked by recipe-line count, then name:")
    emit("")
    emit("| App ingredient | Recipe lines |")
    emit("| --- | --- |")
    for (name, count) in gapLineCounts.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }).prefix(15) {
        emit("| \(name) | \(count) |")
    }
    emit("")

    // 40-pair audited sample: evenly spaced across the sorted pair ids.
    emit("## 40-pair audited sample")
    emit("")
    emit("Evenly spaced across the sorted pair ids; verdicts recomputed by")
    emit("`ContextRules` from the recorded evidence statuses, not restated.")
    emit("")
    emit("| Pair | Swap | Role | Verdict | Why |")
    emit("| --- | --- | --- | --- | --- |")
    let sortedPairs = table.pairs.sorted { $0.id < $1.id }
    let n = sortedPairs.count
    let sampleSize = 40
    var seen = Set<Int>()
    for i in 0..<sampleSize {
        let index = n > 1 ? i * (n - 1) / (sampleSize - 1) : 0
        guard seen.insert(index).inserted else { continue }
        let pair = sortedPairs[index]
        let originalDisplay = table.ingredient(pair.original)?.display ?? pair.original
        let substituteDisplay = table.ingredient(pair.substitute)?.display ?? pair.substitute
        let verdict = ContextRules.verdict(for: pair, requestedRole: pair.role)
        let why = pair.assessment ?? pair.difference
        let whyOneLine = why.replacingOccurrences(of: "|", with: "\\|")
        emit("| \(pair.id) | \(originalDisplay) → \(substituteDisplay) | \(pair.role.rawValue) | \(verdict) | \(whyOneLine) |")
    }
    emit("")

    print(out.joined(separator: "\n"))
}

do {
    try main()
} catch let error as UsageError {
    FileHandle.standardError.write(Data(error.description.utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("flsub-report: \(error)\n".utf8))
    exit(1)
}
