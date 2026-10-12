import FLIngredientFacts
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
    var description: String {
        "usage: flsub-report --table <pairs.json> --recipes <data.json> [--facts <ingredient-facts-dir>] [--originals <originals.jsonl>]"
    }
}

func parseArgs() throws -> (table: String, recipes: String, facts: String?, originals: String?) {
    var args = Array(CommandLine.arguments.dropFirst())
    var table: String?
    var recipes: String?
    var facts: String?
    var originals: String?
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--table":
            guard !args.isEmpty else { throw UsageError() }
            table = args.removeFirst()
        case "--recipes":
            guard !args.isEmpty else { throw UsageError() }
            recipes = args.removeFirst()
        case "--facts":
            guard !args.isEmpty else { throw UsageError() }
            facts = args.removeFirst()
        case "--originals":
            guard !args.isEmpty else { throw UsageError() }
            originals = args.removeFirst()
        default:
            throw UsageError()
        }
    }
    guard let tablePath = table, let recipesPath = recipes else { throw UsageError() }
    // Default: the canonical dataset sits beside the table (data/substitutions
    // -> data/ingredient-facts), mirroring SubstitutionTable.loadDefault().
    let factsDefault = URL(fileURLWithPath: tablePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ingredient-facts")
    let factsDir = facts
        ?? (FileManager.default.fileExists(atPath: factsDefault.path) ? factsDefault.path : nil)
    return (tablePath, recipesPath, factsDir, originals)
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

// MARK: - Originals corpus (JSONL, one recipe object per line)

struct OriginalsCorpus {
    var recipeCount = 0
    var ingredientNames: [String] = []
}

/// Reads `data/recipes/originals/originals.jsonl` from branch
/// `overhaul/original-recipes`, materialized read-only with `git show`
/// (the branch is never checked out or pushed): one JSON object per line,
/// `ingredients` an array of `{name, qty}` entries.
func loadOriginals(path: String) throws -> OriginalsCorpus {
    var corpus = OriginalsCorpus()
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        corpus.recipeCount += 1
        guard let ingredients = object["ingredients"] as? [[String: Any]] else { continue }
        for entry in ingredients {
            if let name = entry["name"] as? String, !name.isEmpty {
                corpus.ingredientNames.append(name)
            }
        }
    }
    return corpus
}

// MARK: - Report body

func main() throws {
    let paths = try parseArgs()
    let tableData = try Data(contentsOf: URL(fileURLWithPath: paths.table))
    // The canonical composition referee: without it every restricted lookup
    // would fail closed for want of facts and the coverage table would lie.
    let table = try SubstitutionTable(
        data: tableData,
        factsDirectory: paths.facts.map { URL(fileURLWithPath: $0) }
    )
    let corpus = try loadRecipes(path: paths.recipes)

    var out: [String] = []
    func emit(_ line: String) { out.append(line) }

    emit("# Substitution coverage report")
    emit("")
    emit("Regenerated deterministically by the `flsub-report` executable in")
    emit("`packages/FLSubstitutions` from the committed table and the bundled recipe data.")
    emit("Regenerate from the repository root:")
    emit("")
    emit("    git fetch origin overhaul/original-recipes")
    emit("    git show origin/overhaul/original-recipes:data/recipes/originals/originals.jsonl > /tmp/originals.jsonl")
    emit("    swift run -c release --package-path packages/FLSubstitutions flsub-report \\")
    emit("      --table data/substitutions/pairs.json \\")
    emit("      --recipes apps/ios/Resources/data.json \\")
    emit("      --originals /tmp/originals.jsonl \\")
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

    // Composition status from the canonical facts store (PR #114 fix list):
    // unknown-composition ingredients are their own class so the formerly
    // "empty class list" bulk resolves into reviewed facts vs explicit
    // unknowns instead of hiding inside the label lists.
    let factsStore = table.factsStore
    var reviewed = 0
    var unknownComposition: [String] = []
    for key in table.ingredients.keys.sorted() {
        let record = table.ingredient(key)
        let probe = record?.factsKey ?? record?.display ?? key
        if factsStore?.resolve(probe) != nil {
            reviewed += 1
        } else {
            unknownComposition.append(key)
        }
    }
    emit("## Composition status (canonical facts store)")
    emit("")
    if factsStore == nil {
        emit("No facts dataset loaded — restricted coverage below is meaningless.")
    } else {
        emit("Ingredient records by composition status in the canonical dataset (data/ingredient-facts):")
    }
    emit("")
    emit("- Resolved in the canonical store (composition reviewed): \(reviewed)")
    emit("- Unknown composition (no canonical record; rechecks ask the user under restrictions): \(unknownComposition.count)")
    if !unknownComposition.isEmpty {
        emit("")
        emit("Unknown-composition ingredients, first 40 by key:")
        emit("")
        emit("\(unknownComposition.prefix(40).joined(separator: ", "))\(unknownComposition.count > 40 ? ", …" : "")")
    }
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


    // Top-30 composition-unknown entries by recipe-line frequency (operator
    // ruling, review round 2): the FLIngredientFacts coverage task (PR #127)
    // reviews the head of this list first. Emitted only when an originals
    // corpus is supplied, so the older invocation keeps its exact output.
    if let originalsPath = paths.originals {
        let originals = try loadOriginals(path: originalsPath)
        let unknownKeys = Set(unknownComposition)

        // The table's own resolution rule, mirrored for originals names:
        // exact, case-insensitive match on key, display, or alias, with the
        // app data's underscore-for-space fallback as the second candidate.
        func tableKey(for name: String) -> String? {
            let candidates = [name, name.replacingOccurrences(of: "_", with: " ")]
            var tried = Set<String>()
            for candidate in candidates where tried.insert(candidate).inserted {
                if let key = try? table.resolveIngredientKey(candidate) { return key }
            }
            return nil
        }

        var bundledUnknown: [String: Int] = [:]
        var bundledUnknownLines = 0
        for recipe in corpus.lines {
            for ref in recipe.refs {
                if let key = appToKey[ref.id], unknownKeys.contains(key) {
                    bundledUnknown[key, default: 0] += 1
                    bundledUnknownLines += 1
                }
            }
        }

        var originalUnknown: [String: Int] = [:]
        var originalMatched = 0
        for name in originals.ingredientNames {
            if let key = tableKey(for: name) {
                originalMatched += 1
                if unknownKeys.contains(key) { originalUnknown[key, default: 0] += 1 }
            }
        }

        var ranked: [(key: String, bundled: Int, original: Int, total: Int)] = []
        for key in unknownKeys {
            let bundledCount = bundledUnknown[key] ?? 0
            let originalCount = originalUnknown[key] ?? 0
            if bundledCount + originalCount > 0 {
                ranked.append((key, bundledCount, originalCount, bundledCount + originalCount))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.key < rhs.key
        }

        emit("## Composition-unknown entries seen most often")
        emit("")
        emit("For the FLIngredientFacts coverage task (PR #127): the table entries whose")
        emit("composition is unknown in the canonical facts store, ranked by how often the")
        emit("ingredient appears in the recipe corpora, so reviewing the facts for the head")
        emit("of this list covers the most recipe lines first. Fail-closed semantics do not")
        emit("depend on this list: an unknown entry is never offered as a verified swap and")
        emit("shows as a check to the user.")
        emit("")
        emit("Occurrences are recipe ingredient lines. Bundled lines come from")
        emit("`apps/ios/Resources/data.json` (required + optional refs, the same line")
        emit("semantics as the Corpus section). Original lines come from")
        emit("`data/recipes/originals/originals.jsonl` on `origin/overhaul/original-recipes`,")
        emit("materialized read-only with `git show` (the branch is never checked out or")
        emit("pushed). A corpus ingredient counts toward a table entry when the table's own")
        emit("resolution matches it: an exact, case-insensitive match on the entry's key,")
        emit("display name, or a recorded alias (plus the app data's")
        emit("underscore-for-space fallback for snake_case ids). Corpus names that match no")
        emit("table entry, or that match a composition-reviewed entry, are not listed here,")
        emit("so every count below is a lower bound on the ingredient's true frequency.")
        emit("")
        emit("Originals corpus: \(originals.recipeCount) recipes, \(originals.ingredientNames.count) ingredient lines, \(originalMatched) resolved to a table entry. Bundled lines resolved to an unknown-composition entry: \(bundledUnknownLines).")
        emit("")
        emit("| # | Table entry | Bundled lines | Original lines | Total |")
        emit("| --- | --- | --- | --- | --- |")
        for (index, row) in ranked.prefix(30).enumerated() {
            let display = table.ingredient(row.key)?.display ?? row.key
            let safeDisplay = display.replacingOccurrences(of: "|", with: "\\|")
            emit("| \(index + 1) | \(safeDisplay) | \(row.bundled) | \(row.original) | \(row.total) |")
        }
        emit("")
        emit("First 30 of the \(ranked.count) composition-unknown entries with at least one occurrence; the remaining \(unknownComposition.count - ranked.count) of \(unknownComposition.count) have zero occurrences in both corpora.")
        emit("")
    }

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
