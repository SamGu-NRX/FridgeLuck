import Foundation

/// One linter finding: the unsafe phrasing, the reviewed rule it violates
/// (with its verbatim source quote), and a proposed safe rewrite of the step.
public struct LintFlag: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case appearanceDoneness
        case timeOnlyCooking
        case rawEggNoWarning
        case ambientThawing
        case leftoversHeldOut
        case reheatingWithoutThermometer
    }

    public let kind: Kind
    /// The `rules.json` rule id the flag enforces.
    public let ruleID: String
    /// The matched phrase (empty for context-level findings).
    public let phrase: String
    /// "ORG — Title" of the primary source.
    public let sourceAttribution: String
    public let sourceURL: String
    /// A verbatim quote from the primary source supporting the flag.
    public let sourceQuote: String
    /// The FSIS class minimum (°F) the safe rewrite points at, when the flag
    /// carries a temperature requirement (nil for handling-only findings).
    public let suggestedTempF: Double?
    /// The full proposed replacement text for the step.
    public let suggestedRewrite: String

    public init(kind: Kind, ruleID: String, phrase: String, sourceAttribution: String,
                sourceURL: String, sourceQuote: String, suggestedTempF: Double? = nil,
                suggestedRewrite: String) {
        self.kind = kind
        self.ruleID = ruleID
        self.phrase = phrase
        self.sourceAttribution = sourceAttribution
        self.sourceURL = sourceURL
        self.sourceQuote = sourceQuote
        self.suggestedTempF = suggestedTempF
        self.suggestedRewrite = suggestedRewrite
    }
}

/// Flags unsafe phrasing in recipe steps and proposes safe rewrites.
///
/// Phrase gating mirrors the suite C corpus linter (`rs.py`): the forbidden
/// doneness phrases are the `_COLOUR_OR_TIME_DONENESS` set (golden, no longer
/// pink, cooked through, no longer translucent, opaque, browned through, firm
/// to the touch) plus "juices run clear" and "no pink", which FSIS "Doneness
/// Versus Safety" rejects separately. Appearance and time-only flags apply to
/// steps in an animal-protein/leftover/egg context — recipes that need no
/// thermometer check (a cake, a salad) are not flagged.
public struct StepLinter {
    private let rulebook: Rulebook
    private let lookup: DonenessLookup

    public init(rulebook: Rulebook) {
        self.rulebook = rulebook
        self.lookup = DonenessLookup(rulebook: rulebook)
    }

    // MARK: Forbidden appearance phrases (rs.py-aligned + FSIS juice/pink cues)

    /// (regex pattern, matched-phrase description). Order = report order.
    static let appearancePatterns: [(pattern: String, label: String)] = [
        (#"no longer pink"#, "no longer pink"),
        (#"no pink"#, "no pink"),
        (#"juices? (?:run|runs) clear"#, "juices run clear"),
        (#"clear juices"#, "clear juices"),
        (#"cooked through"#, "cooked through"),
        (#"no longer translucent"#, "no longer translucent"),
        (#"browned through"#, "browned through"),
        (#"firm to the touch"#, "firm to the touch"),
        (#"golden"#, "golden"),
        (#"opaque"#, "opaque"),
    ]

    // MARK: Phrases that show the step already checks a temperature

    static let thermometerPatterns = [
        #"thermometer"#,
        #"internal temperature"#,
        #"\d+(?:\.\d+)?\s*°\s*[cf]"#,
        #"\d+\s*degrees?\s+(?:c|f|celsius|fahrenheit)\b"#,
        #"reaches? (?:an internal )?temperature"#,
    ]

    static let durationPattern =
        #"\b\d+(?:[.,]\d+)?(?:\s*(?:-|–|to)\s*\d+(?:[.,]\d+)?)?\s*(?:minutes?|mins?|hours?|hrs?|hrs)\b"#

    static let ambientThawPattern =
        #"(?:thaw|defrost)\b[^.]*(?:on the counter|at room temperature|room-temp|in hot water|under hot water|outside|in the sun)|(?:counter|room temperature)[^.]*\b(?:thaw|defrost)"#

    static let leftoversOutPattern =
        #"(?:leftover|leftovers|cooked (?:rice|pasta|chicken|meat|fish|food|dish))\b[^.]*\b(?:left (?:out|at room temperature)|leaving (?:it|them) out|(?:at|to) room temperature|on the counter|stand(?:ing)? at room temperature)"#

    /// Handling steps — cooling, chilling, marinating, resting, proving —
    /// name durations that are not cooking times.
    static let handlingVerbPattern =
        #"\b(?:refrigerat\w*|chill\w*|freez\w*|frozen|cool(?:s|ed|ing)?|marinat\w*|soak\w*|rest(?:s|ed|ing)?|proof\w*|proving|stand(?:s|ing)?)\b"#

    /// Appearance phrases that inherently claim protein doneness — unsafe on
    /// their own, with or without a protein word in context.
    static let proteinImpliedPatterns = [
        "no longer pink", "no pink", "not pink", "no longer translucent",
        "opaque", "juices run clear", "juice runs clear", "clear juices",
        "cooked through", "browned through", "firm to the touch",
    ]

    // MARK: API

    /// Lint one recipe step. `recipe` is the surrounding recipe text (title,
    /// ingredients, other steps) used for class context, mirroring how rs.py
    /// gates colour/time flags on the recipe's protein classes.
    public func lint(step: String, recipe: String) -> [LintFlag] {
        var flags: [LintFlag] = []
        let loweredStep = step.lowercased()
        let loweredRecipe = recipe.lowercased()
        let hasThermometerCheck = Self.anyMatch(Self.thermometerPatterns, in: loweredStep)

        // Protein context: the step itself, else the recipe it belongs to
        // (rs.py gates colour/time flags on the recipe's protein classes).
        let proteinMatch = lookup.check(text: step) ?? lookup.check(text: recipe)
        let stepProtein = lookup.check(text: step)

        // 1. Doneness by appearance — never a safety verdict. Phrases that
        // inherently claim protein doneness ("no longer pink") flag
        // standalone; pure colour phrases ("golden") need protein or leftover
        // context so browning onions or pastry is not misread.
        if !hasThermometerCheck, let appearance = Self.firstMatch(Self.appearancePatterns.map { $0.pattern }, in: loweredStep) {
            let label = Self.appearancePatterns.first { Self.matches($0.pattern, in: loweredStep) }?.label ?? appearance
            let proteinImplied = Self.proteinImpliedPatterns.contains { loweredStep.contains($0) }
            if proteinImplied || proteinMatch != nil || mentionsLeftovers(loweredStep) || mentionsLeftovers(loweredRecipe) {
                flags.append(makeAppearanceFlag(step: step, phrase: label))
            }
        }

        // 2. Time-only cooking for protein steps. Handling steps (cooling,
        // chilling, resting, marinating) name durations that are not cooking
        // times and never flag.
        if !hasThermometerCheck,
           !Self.matches(Self.handlingVerbPattern, in: loweredStep),
           let protein = stepProtein ?? (mentionsLeftovers(loweredStep) ? lookup.rule(for: .leftovers).map { DonenessMatch(rule: $0, matchedKeyword: "leftover") } : nil),
           Self.matches(Self.durationPattern, in: loweredStep) {
            flags.append(makeTimeOnlyFlag(step: step, protein: protein))
        }

        // 3. Raw-egg dishes without the pasteurized-egg warning (either
        // spelling of the treatment).
        if mentionsRawEggDish(loweredStep) || (mentionsRawEggDish(loweredRecipe) && mentionsEggs(loweredStep)),
           !matchesAny(loweredStep, ["pasteuriz", "pasteuris"]),
           !matchesAny(loweredRecipe, ["pasteuriz", "pasteuris"]) {
            flags.append(makeRawEggFlag(step: step))
        }

        // 4. Ambient thawing.
        if Self.matches(Self.ambientThawPattern, in: loweredStep) {
            flags.append(makeThawFlag(step: step))
        }

        // 5. Leftovers held out at room temperature.
        if Self.matches(Self.leftoversOutPattern, in: loweredStep) {
            flags.append(makeLeftoversOutFlag(step: step))
        }

        // 6. Reheating without a temperature check.
        if !hasThermometerCheck, mentionsReheat(loweredStep),
           mentionsLeftovers(loweredStep) || mentionsLeftovers(loweredRecipe) || Self.matches(#"\b(?:sauce|soup|gravy|stew|casserole|rice|pasta|curry)\b"#, in: loweredStep) {
            flags.append(makeReheatFlag(step: step))
        }

        return flags
    }

    /// Lint a whole instruction block: splits the newline-numbered steps and
    /// lints each with the full recipe text as context.
    public func lintRecipe(title: String, ingredients: String, instructions: String) -> [(stepIndex: Int, step: String, flags: [LintFlag])] {
        let context = title + " " + ingredients + " " + instructions
        return Self.numberedSteps(in: instructions).enumerated().map { index, step in
            (index, step, lint(step: step, recipe: context))
        }
    }

    /// Splits "1. Do this\n2. Do that" style instructions into steps;
    /// continuation lines join the step they belong to.
    public static func numberedSteps(in instructions: String) -> [String] {
        var steps: [String] = []
        for line in instructions.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if startsWithStepNumber(trimmed) {
                steps.append(trimmed)
            } else if !steps.isEmpty {
                steps[steps.count - 1] += " " + trimmed
            }
        }
        return steps
    }

    /// True when the line begins with a step number like "1." or "2)".
    static func startsWithStepNumber(_ line: String) -> Bool {
        var rest = Substring(line)
        var digits = 0
        while let first = rest.first, first.isNumber {
            rest = rest.dropFirst()
            digits += 1
        }
        guard digits > 0, digits <= 3 else { return false }
        return rest.first == "." || rest.first == ")"
    }

    // MARK: Detection helpers

    private func mentionsLeftovers(_ text: String) -> Bool {
        matchesAny(text, ["leftover", "left overs", "left-over", "reheat", "re-warm"])
    }

    private func mentionsEggs(_ text: String) -> Bool {
        matchesAny(text, ["egg", "eggs", "yolk", "yolks"])
    }

    private func mentionsReheat(_ text: String) -> Bool {
        matchesAny(text, ["reheat", "re-warm", "rewarm", "warm up", "warm through", "warm the", "warm it", "microwave"])
    }

    private func mentionsRawEggDish(_ text: String) -> Bool {
        matchesAny(text, [
            "caesar", "tiramisu", "mayonnaise", "eggnog", "hollandaise",
            "ice cream", "mousse", "cookie dough", "raw egg",
        ])
    }

    private func matchesAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { Self.matches("\\b" + NSRegularExpression.escapedPattern(for: $0), in: text) }
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        firstMatch([pattern], in: text) != nil
    }

    static func firstMatch(_ patterns: [String], in text: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    static func anyMatch(_ patterns: [String], in text: String) -> Bool {
        firstMatch(patterns, in: text) != nil
    }

    // MARK: Flag construction (rewrites are data-driven from the rulebook)

    private func rule(_ id: String) -> Rule? { rulebook.rules.first { $0.id == id } }

    private func source(_ id: String, quoteIndex: Int = 0) -> (attribution: String, url: String, quote: String)? {
        guard let rule = rule(id), let citation = rulebook.citations(for: rule).first,
              citation.quotes.indices.contains(quoteIndex) else { return nil }
        return (citation.attribution, citation.url, citation.quotes[quoteIndex])
    }

    private func makeAppearanceFlag(step: String, phrase: String) -> LintFlag {
        let match = lookup.check(text: step)
        let proteinRule = match?.rule ?? rule(forClass: .meatPoultry) ?? rule("thermometer-only-reliable")
        guard let src = source("thermometer-only-reliable") else { fatalError("rulebook invariant: thermometer-only-reliable cited") }
        let rewrite: String
        if let rule = proteinRule, let check = rule.check {
            rewrite = "Cook until \(check.placement.map { "the \($0)" } ?? "the thickest part") reaches \(Int(check.tempC)) °C (\(Int(check.tempF)) °F) on a food thermometer — check at the timer rather than judging appearance. (Source: \(src.attribution), \(src.url), retrieved \(rulebook.retrieved): \"Appearance and color are not reliable indicators of safety or doneness.\")"
        } else {
            rewrite = step
        }
        return LintFlag(
            kind: .appearanceDoneness,
            ruleID: "thermometer-only-reliable",
            phrase: phrase,
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedTempF: proteinRule?.check?.tempF,
            suggestedRewrite: rewrite
        )
    }

    private func makeTimeOnlyFlag(step: String, protein: DonenessMatch) -> LintFlag {
        let rule = protein.rule
        let check = rule.check
        var rewrite = step
        if let check {
            let placement = check.placement.map { " in the \($0)" } ?? ""
            let rest = check.restMinutes > 0 ? ", then rest \(Int(check.restMinutes)) minutes" : ""
            rewrite = "Cook until a food thermometer\(placement) reads \(Int(check.tempC)) °C (\(Int(check.tempF)) °F)\(rest) — the timer only tells you when to check. (Source: \(rulebook.citations(for: rule).first?.attribution ?? "USDA FSIS"), retrieved \(rulebook.retrieved))"
        }
        guard let src = source(rule.id) else { fatalError("rulebook invariant: protein rule cited") }
        return LintFlag(
            kind: .timeOnlyCooking,
            ruleID: rule.id,
            phrase: protein.matchedKeyword,
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedTempF: check?.tempF,
            suggestedRewrite: rewrite
        )
    }

    private func makeRawEggFlag(step: String) -> LintFlag {
        let rewrite = "Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("raw-egg-recipes-pasteurized") else { fatalError("rulebook invariant: raw-egg rule cited") }
        return LintFlag(
            kind: .rawEggNoWarning,
            ruleID: "raw-egg-recipes-pasteurized",
            phrase: "",
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedTempF: FoodClass.egg.minimumTempF,
            suggestedRewrite: rewrite
        )
    }

    private func makeThawFlag(step: String) -> LintFlag {
        let rewrite = "Thaw in the refrigerator, in cold water (leak-proof bag, water changed every 30 minutes), or in the microwave — and cook immediately after cold-water or microwave thawing. Never thaw at room temperature. (Source: USDA FSIS — The Big Thaw, retrieved \(rulebook.retrieved))"
        guard let src = source("thaw-counter-unsafe") else { fatalError("rulebook invariant: thaw rule cited") }
        return LintFlag(
            kind: .ambientThawing,
            ruleID: "thaw-counter-unsafe",
            phrase: "",
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedRewrite: rewrite
        )
    }

    private func makeLeftoversOutFlag(step: String) -> LintFlag {
        let rewrite = "Refrigerate or freeze leftovers within 2 hours (within 1 hour above 90 °F / 32 °C); discard perishable food left out longer. (Source: USDA FSIS — Leftovers and Food Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("two-hour-rule") else { fatalError("rulebook invariant: two-hour rule cited") }
        return LintFlag(
            kind: .leftoversHeldOut,
            ruleID: "two-hour-rule",
            phrase: "",
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedTempF: FoodClass.leftovers.minimumTempF,
            suggestedRewrite: rewrite
        )
    }

    private func makeReheatFlag(step: String) -> LintFlag {
        let rewrite = "Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("leftovers-reheat-165") else { fatalError("rulebook invariant: reheat rule cited") }
        return LintFlag(
            kind: .reheatingWithoutThermometer,
            ruleID: "leftovers-reheat-165",
            phrase: "",
            sourceAttribution: src.attribution,
            sourceURL: src.url,
            sourceQuote: src.quote,
            suggestedTempF: FoodClass.leftovers.minimumTempF,
            suggestedRewrite: rewrite
        )
    }

    private func rule(forClass foodClass: FoodClass) -> Rule? {
        rulebook.rules.first { $0.foodClass == foodClass && $0.check != nil }
    }
}
