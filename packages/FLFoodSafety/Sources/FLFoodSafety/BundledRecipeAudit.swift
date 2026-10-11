import Foundation

// Bundled-corpus audit support: parses the positional data.json format (the
// same shape `BundledDataLoader` decodes in the app) and renders the
// BUNDLED-RECIPE-AUDIT.md report. Pure functions of the inputs — the audit
// file must be byte-reproducible (no timestamps, no locale dependence).

public struct BundledRecipe: Sendable {
    public let id: Int
    public let title: String
    /// (ingredient id, grams) pairs — the "required" column of the array.
    public let requiredIngredients: [(id: Int, grams: Double)]
    public let instructions: String

    public init(id: Int, title: String, requiredIngredients: [(id: Int, grams: Double)], instructions: String) {
        self.id = id
        self.title = title
        self.requiredIngredients = requiredIngredients
        self.instructions = instructions
    }
}

public struct BundledDataSet: Sendable {
    public let ingredientNames: [Int: String]
    public let recipes: [BundledRecipe]

    public init(ingredientNames: [Int: String], recipes: [BundledRecipe]) {
        self.ingredientNames = ingredientNames
        self.recipes = recipes
    }
}

public enum BundledRecipeAuditError: Error, CustomStringConvertible {
    case format(String)
    public var description: String {
        switch self {
        case .format(let message): return "data.json does not match the bundled positional format: \(message)"
        }
    }
}

public enum BundledRecipeAudit {
    /// Parses `apps/ios/Resources/data.json`: top-level
    /// `{ingredients: {id: [name, ...]}, recipes: [[id, title, time, servings,
    /// required[[id,grams]], optional[...], instructions, tagBitmask]]}`.
    public static func loadBundledData(path: String) throws -> BundledDataSet {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let dict = raw as? [String: Any],
              let ingredientDict = dict["ingredients"] as? [String: [Any]],
              let recipeList = dict["recipes"] as? [[Any]] else {
            throw BundledRecipeAuditError.format("top-level shape")
        }
        var names: [Int: String] = [:]
        for (key, fields) in ingredientDict {
            guard let id = Int(key), let name = fields.first as? String else { continue }
            names[id] = name
        }
        var recipes: [BundledRecipe] = []
        for item in recipeList {
            guard item.count >= 8,
                  let id = item[0] as? Int,
                  let title = item[1] as? String,
                  let required = item[4] as? [[Any]],
                  let instructions = item[6] as? String else {
                throw BundledRecipeAuditError.format("recipe row \(recipes.count)")
            }
            let pairs = required.compactMap { pair -> (Int, Double)? in
                guard pair.count >= 2, let ingId = pair[0] as? Int else { return nil }
                let grams = (pair[1] as? Double) ?? ((pair[1] as? Int).map(Double.init) ?? 0)
                return (ingId, grams)
            }
            recipes.append(BundledRecipe(id: id, title: title, requiredIngredients: pairs, instructions: instructions))
        }
        return BundledDataSet(ingredientNames: names, recipes: recipes)
    }

    public struct RecipeLintResult: Sendable {
        public let recipe: BundledRecipe
        /// (step index within the numbered instructions, step text, flags).
        public let flaggedRows: [(stepIndex: Int, step: String, flags: [LintFlag])]
    }

    /// Lints every recipe; deterministic and ordered by corpus position.
    public static func lintCorpus(rulebook: Rulebook, data: BundledDataSet) -> [RecipeLintResult] {
        let linter = StepLinter(rulebook: rulebook)
        return data.recipes.map { recipe in
            let names = recipe.requiredIngredients.compactMap { data.ingredientNames[$0.id] }.joined(separator: ", ")
            let flagged = linter.lintRecipe(title: recipe.title, ingredients: names, instructions: recipe.instructions)
                .filter { !$0.flags.isEmpty }
            return RecipeLintResult(recipe: recipe, flaggedRows: flagged)
        }
    }

    /// Renders the audit markdown. Byte-reproducible given the same rulebook
    /// and corpus.
    public static func renderReport(rulebook: Rulebook, data: BundledDataSet) -> String {
        let results = lintCorpus(rulebook: rulebook, data: data)
        var out: [String] = []

        out.append("# Bundled Recipe Audit (food safety)")
        out.append("")
        out.append("Regenerates from the committed command in `packages/FLFoodSafety/README.md`. Deterministic: byte-identical for the same rulebook and corpus — no timestamps, no locale dependence.")
        out.append("")
        out.append("- Rulebook: `data/food-safety/rules.json` (schema 1; quotes retrieved \(rulebook.retrieved) from USDA FSIS, FDA, FoodSafety.gov or CDC)")
        out.append("- Corpus: `apps/ios/Resources/data.json` — \(data.recipes.count) bundled recipes, all listed in the index below")
        out.append("- Scope: safety phrasing only — doneness by appearance, time-only protein cooking, raw-egg warnings, ambient thawing, leftovers held out, reheating without a thermometer. Rights, nutrition and language review are separate suites.")
        out.append("- Doneness standard: a food thermometer at the USDA FSIS safe minimum internal temperature. Appearance (colour, no pink, clear juices, firmness, browning) is never a safety verdict.")

        let flagged = results.filter { !$0.flaggedRows.isEmpty }
        let totalFlags = flagged.reduce(0) { $0 + $1.flaggedRows.reduce(0) { $0 + $1.flags.count } }

        out.append("")
        out.append("## Summary")
        out.append("")
        out.append("| Metric | Value |")
        out.append("| --- | --- |")
        out.append("| Recipes audited | \(data.recipes.count) |")
        out.append("| Recipes with flagged steps | \(flagged.count) |")
        out.append("| Flagged steps (total) | \(totalFlags) |")
        for kind in LintFlag.Kind.allCases {
            let count = flagged.reduce(0) { $0 + $1.flaggedRows.reduce(0) { $0 + $1.flags.filter { $0.kind == kind }.count } }
            out.append("| \(kind.rawValue) flags | \(count) |")
        }

        out.append("")
        out.append("## Recipe index")
        out.append("")
        out.append("| ID | Recipe | Flagged steps |")
        out.append("| --- | --- | --- |")
        for result in results {
            let mark = result.flaggedRows.isEmpty ? "—" : "\(result.flaggedRows.count)"
            out.append("| \(result.recipe.id) | \(result.recipe.title) | \(mark) |")
        }

        out.append("")
        out.append("## Findings")
        out.append("")
        if flagged.isEmpty {
            out.append("No flags in the bundled corpus.")
        }
        for result in flagged {
            out.append("### \(result.recipe.id) — \(result.recipe.title)")
            out.append("")
            for row in result.flaggedRows {
                let stepText = row.step.replacingOccurrences(
                    of: "^\\d+[.)]\\s*",
                    with: "",
                    options: .regularExpression
                )
                for flag in row.flags {
                    out.append("- **Step \(row.stepIndex + 1)** — `\(flag.kind.rawValue)` — rule `\(flag.ruleID)`")
                    out.append("  - Step text: “\(stepText)”")
                    out.append("  - Problem: \(flag.phrase.isEmpty ? "unsafe handling pattern" : "“\(flag.phrase)” states doneness or safety by appearance/time") — \(flag.sourceAttribution): “\(flag.sourceQuote)” (<\(flag.sourceURL)>)")
                    out.append("  - Proposed safe rewrite: \(flag.suggestedRewrite)")
                }
            }
            out.append("")
        }

        out.append("## Regeneration")
        out.append("")
        out.append("```sh")
        out.append("swift build -c release --package-path packages/FLFoodSafety")
        out.append("packages/FLFoodSafety/.build/release/flfoodsafety-audit --repo-root . > data/food-safety/BUNDLED-RECIPE-AUDIT.md")
        out.append("```")
        out.append("")
        return out.joined(separator: "\n") + "\n"
    }
}
