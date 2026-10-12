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
///
/// Beyond the phrase layer, `findings(step:recipe:safetyField:)` verifies the
/// strict canon contract (`data/food-safety/README.md` clauses 1–7): every
/// protein-cooking step must carry a doneness check that names a thermometer,
/// states an internal temperature at or above the class minimum, and states
/// the required rest time — read from the rulebook data, never hardcoded.
/// Uncertainty fails closed; nothing defaults to pass.
public struct StepLinter {
    /// The decoded rulebook, or nil when the linter was built from unusable
    /// rules data (fail-closed mode, contract clause 7).
    let rulebook: Rulebook?
    /// Lookup built over `rulebook` when decoded, else nil.
    let lookup: DonenessLookup?
    /// Why the rulebook is unusable (nil when decoded).
    let rulebookFailure: String?

    public init(rulebook: Rulebook) {
        self.rulebook = rulebook
        self.lookup = DonenessLookup(rulebook: rulebook)
        self.rulebookFailure = nil
    }

    /// Fail-closed construction: nil or undecodable rules data produces a
    /// linter whose every query reports what is missing (clause 7) instead of
    /// throwing or defaulting to pass.
    public init(rulebookData: Data?) {
        guard let data = rulebookData else {
            self.init(failure: "no rules data was provided (the rules file is missing)")
            return
        }
        do {
            self.init(rulebook: try Rulebook.decode(data))
        } catch {
            self.init(failure: "the rules file could not be decoded or validated: \(Self.describe(error))")
        }
    }

    private init(failure: String) {
        rulebook = nil
        lookup = nil
        rulebookFailure = failure
    }

    static func describe(_ error: Error) -> String {
        if let rulebookError = error as? RulebookError {
            return rulebookError.description
        }
        return String(describing: error)
    }

    // MARK: Forbidden appearance phrases (rs.py-aligned + FSIS juice/pink cues)

    /// (regex pattern, matched-phrase description). Order = report order.
    static let appearancePatterns: [(pattern: String, label: String)] = [
        (#"no longer pink"#, "no longer pink"),
        (#"no pink"#, "no pink"),
        (#"not pink"#, "not pink"),
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
    ///
    /// This is the legacy phrase layer: it finds the six original failure
    /// classes and stays byte-stable for `BundledRecipeAudit`. The strict canon
    /// contract is `findings(step:recipe:safetyField:)`.
    public func lint(step: String, recipe: String) -> [LintFlag] {
        guard let lookup = lookup, let rulebook = rulebook else { return [] }
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
                flags.append(makeAppearanceFlag(step: step, phrase: label, rulebook: rulebook, lookup: lookup))
            }
        }

        // 2. Time-only cooking for protein steps. Handling steps (cooling,
        // chilling, resting, marinating) name durations that are not cooking
        // times and never flag.
        if !hasThermometerCheck,
           !Self.matches(Self.handlingVerbPattern, in: loweredStep),
           let protein = stepProtein ?? (mentionsLeftovers(loweredStep) ? lookup.rule(for: .leftovers).map { DonenessMatch(rule: $0, matchedKeyword: "leftover") } : nil),
           Self.matches(Self.durationPattern, in: loweredStep) {
            flags.append(makeTimeOnlyFlag(step: step, protein: protein, rulebook: rulebook))
        }

        // 3. Raw-egg dishes without the pasteurized-egg warning (either
        // spelling of the treatment).
        if mentionsRawEggDish(loweredStep) || (mentionsRawEggDish(loweredRecipe) && mentionsEggs(loweredStep)),
           !matchesAny(loweredStep, ["pasteuriz", "pasteuris"]),
           !matchesAny(loweredRecipe, ["pasteuriz", "pasteuris"]) {
            flags.append(makeRawEggFlag(step: step, rulebook: rulebook))
        }

        // 4. Ambient thawing.
        if Self.matches(Self.ambientThawPattern, in: loweredStep) {
            flags.append(makeThawFlag(step: step, rulebook: rulebook))
        }

        // 5. Leftovers held out at room temperature.
        if Self.matches(Self.leftoversOutPattern, in: loweredStep) {
            flags.append(makeLeftoversOutFlag(step: step, rulebook: rulebook))
        }

        // 6. Reheating without a temperature check.
        if !hasThermometerCheck, mentionsReheat(loweredStep),
           mentionsLeftovers(loweredStep) || mentionsLeftovers(loweredRecipe) || Self.matches(#"\b(?:sauce|soup|gravy|stew|casserole|rice|pasta|curry)\b"#, in: loweredStep) {
            flags.append(makeReheatFlag(step: step, rulebook: rulebook))
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
    /// continuation lines join the step they belong to. An unnumbered line
    /// before the first numbered one starts a step of its own: instruction
    /// text the user reads is never dropped before linting.
    public static func numberedSteps(in instructions: String) -> [String] {
        var steps: [String] = []
        for line in instructions.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if startsWithStepNumber(trimmed) || steps.isEmpty {
                steps.append(trimmed)
            } else {
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

    private func rule(_ id: String, rulebook: Rulebook) -> Rule? {
        rulebook.rules.first { $0.id == id }
    }

    private func source(_ id: String, rulebook: Rulebook, quoteIndex: Int = 0) -> (attribution: String, url: String, quote: String)? {
        guard let rule = rule(id, rulebook: rulebook), let citation = rulebook.citations(for: rule).first,
              citation.quotes.indices.contains(quoteIndex) else { return nil }
        return (citation.attribution, citation.url, citation.quotes[quoteIndex])
    }

    private func makeAppearanceFlag(step: String, phrase: String, rulebook: Rulebook, lookup: DonenessLookup) -> LintFlag {
        let match = lookup.check(text: step)
        let proteinRule = match?.rule ?? rule(forClass: .meatPoultry, rulebook: rulebook) ?? rule("thermometer-only-reliable", rulebook: rulebook)
        guard let src = source("thermometer-only-reliable", rulebook: rulebook) else { fatalError("rulebook invariant: thermometer-only-reliable cited") }
        let rewrite: String
        if let rule = proteinRule, let check = rule.check {
            rewrite = "Cook until \(check.placement.map { $0 } ?? "the thickest part") reaches \(Int(check.tempC)) °C (\(Int(check.tempF)) °F) on a food thermometer — check at the timer rather than judging appearance. (Source: \(src.attribution), \(src.url), retrieved \(rulebook.retrieved): \"Appearance and color are not reliable indicators of safety or doneness.\")"
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

    private func makeTimeOnlyFlag(step: String, protein: DonenessMatch, rulebook: Rulebook) -> LintFlag {
        let rule = protein.rule
        let check = rule.check
        var rewrite = step
        if let check {
            let placement = check.placement.map { " in \($0)" } ?? ""
            let verb = rule.foodClass == .leftovers ? "Reheat" : "Cook"
            let rest = check.restMinutes > 0 ? ", then rest \(Int(check.restMinutes)) minutes" : ""
            rewrite = "\(verb) until a food thermometer\(placement) reads \(Int(check.tempC)) °C (\(Int(check.tempF)) °F)\(rest) — the timer only tells you when to check. (Source: \(rulebook.citations(for: rule).first?.attribution ?? "USDA FSIS"), retrieved \(rulebook.retrieved))"
        }
        guard let src = source(rule.id, rulebook: rulebook) else { fatalError("rulebook invariant: protein rule cited") }
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

    private func makeRawEggFlag(step: String, rulebook: Rulebook) -> LintFlag {
        let rewrite = "Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("raw-egg-recipes-pasteurized", rulebook: rulebook) else { fatalError("rulebook invariant: raw-egg rule cited") }
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

    private func makeThawFlag(step: String, rulebook: Rulebook) -> LintFlag {
        let rewrite = "Thaw in the refrigerator, in cold water (leak-proof bag, water changed every 30 minutes), or in the microwave — and cook immediately after cold-water or microwave thawing. Never thaw at room temperature. (Source: USDA FSIS — The Big Thaw, retrieved \(rulebook.retrieved))"
        guard let src = source("thaw-counter-unsafe", rulebook: rulebook) else { fatalError("rulebook invariant: thaw rule cited") }
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

    private func makeLeftoversOutFlag(step: String, rulebook: Rulebook) -> LintFlag {
        let rewrite = "Refrigerate or freeze leftovers within 2 hours (within 1 hour above 90 °F / 32 °C); discard perishable food left out longer. (Source: USDA FSIS — Leftovers and Food Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("two-hour-rule", rulebook: rulebook) else { fatalError("rulebook invariant: two-hour rule cited") }
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

    private func makeReheatFlag(step: String, rulebook: Rulebook) -> LintFlag {
        let rewrite = "Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved \(rulebook.retrieved))"
        guard let src = source("leftovers-reheat-165", rulebook: rulebook) else { fatalError("rulebook invariant: reheat rule cited") }
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

    private func rule(forClass foodClass: FoodClass, rulebook: Rulebook) -> Rule? {
        rulebook.rules.first { $0.foodClass == foodClass && $0.check != nil }
    }
}

// MARK: - Strict canon verification (data/food-safety/README.md clauses 1–7)

public extension StepLinter {
    /// How the strict layer reads a step: a protein-cooking step bound to its
    /// class rule, a reheating step bound to the reheating rule, a thawing
    /// step (safe-method check only — the legacy layer flags unsafe thawing),
    /// or anything else (no doneness requirement).
    enum StepContext: Equatable, Sendable {
        case cooking(DonenessMatch)
        case reheating(DonenessMatch)
        case thawing
        case other
    }

    /// The strict canon findings for one step: everything the legacy phrase
    /// layer finds, plus verification that the step's doneness check counts —
    /// thermometer named (clause 1), internal temperature at or above the class
    /// minimum in °F or °C (clause 2), rest time stated where the class
    /// requires one (clause 3). Oven/pan/microwave temperatures never count
    /// (clause 4); a structured safety field that the text does not show is a
    /// finding (clause 5); an unclassifiable protein flags for review, never a
    /// pass (clause 6); uncertainty fails closed (clause 7).
    ///
    /// `safetyField` is the raw JSON of the record's structured safety field —
    /// the corpus shape `{"class": <food_class>, "temp_f": N, "method":
    /// "thermometer", "source": <title + URL>}`. A field the text does not
    /// show, an unparseable field or an unknown class all fail closed.
    func findings(step: String, recipe: String = "", safetyField: Data? = nil) -> [LintFinding] {
        // Clause 7 first: without a usable rulebook there are no reviewed rules
        // to check against, so every query fails closed.
        if let failure = rulebookFailure {
            return [LintFinding(
                kind: .failClosed, ruleID: "", phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "", detail: failure, currentText: step
            )]
        }
        guard let rulebook = rulebook, let lookup = lookup else {
            return [LintFinding(
                kind: .failClosed, ruleID: "", phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "", detail: "no usable rulebook", currentText: step
            )]
        }

        var found: [LintFinding] = []
        let context = classify(step: step, recipe: recipe, lookup: lookup)

        // Clause 6: unclassifiable protein — a reviewer decides, never a pass.
        if case .other = context,
           Self.matches(Self.cookingVerbPattern, in: step.lowercased()),
           DonenessLookup.mentionsProtein(step),
           lookup.check(text: step) == nil, lookup.check(text: recipe) == nil {
            found.append(LintFinding(
                kind: .flagForReview, ruleID: "", phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "",
                detail: "the step names a protein (\"\(step.trimmingCharacters(in: .whitespaces))\") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass",
                currentText: step
            ))
        }

        // Strict doneness verification for cooking and reheating steps.
        switch context {
        case .cooking(let match), .reheating(let match):
            found.append(contentsOf: verify(step: step, match: match, rulebook: rulebook))
        case .thawing, .other:
            break
        }

        // Legacy phrase-layer findings (six classes), lifted into the strict
        // format. The strict umbrella is suppressed when a named legacy class
        // already describes the defect.
        let legacy = lint(step: step, recipe: recipe).map {
            LintFinding(from: $0, currentText: step)
        }
        let legacyKinds = Set(legacy.map { $0.kind })
        let umbrellaSuppressed = !legacyKinds.isDisjoint(with: [.timeOnlyCooking, .appearanceDoneness, .reheatingWithoutThermometer])
        if umbrellaSuppressed {
            found.removeAll { $0.kind == .missingInternalTemperature }
        }
        found.append(contentsOf: legacy)

        // Clause 5: metadata the text does not show is a finding, not a pass.
        if let fieldData = safetyField {
            found.append(contentsOf: verifySafetyField(
                fieldData, step: step, rulebook: rulebook, lookup: lookup,
                textCheckValid: textHasValidCheck(step, context: context)
            ))
        }

        // Deterministic report order, one finding per kind.
        var seen = Set<LintFinding.Kind>()
        // Fail closed dominates: when the record cannot be evaluated, the
        // fail-closed verdict is the finding — no per-step diagnoses beside it.
        if found.contains(where: { $0.kind == .failClosed }) {
            return found.filter { $0.kind == .failClosed }
        }
        return found.filter { seen.insert($0.kind).inserted }
            .sorted { (LintFinding.reportOrder.firstIndex(of: $0.kind) ?? 0) < (LintFinding.reportOrder.firstIndex(of: $1.kind) ?? 0) }
    }

    /// Strict findings for a whole instruction block. `safetyFields` maps a
    /// zero-based step index to the raw JSON of that record's structured
    /// safety field (empty dictionary when the records carry none).
    func findingsForRecipe(title: String, ingredients: String, instructions: String, safetyFields: [Int: Data] = [:]) -> [(stepIndex: Int, step: String, findings: [LintFinding])] {
        let context = title + " " + ingredients + " " + instructions
        let steps = Self.numberedSteps(in: instructions)
        // Clause 7: instructions that decode but yield no lintable step lines
        // cannot be evaluated — fail closed instead of reporting a clean pass.
        if steps.isEmpty {
            return [(0, "", [LintFinding(
                kind: .failClosed, ruleID: "", phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "",
                detail: "the record's instructions contain no lintable step lines — unparseable instruction text fails closed instead of passing clean",
                currentText: instructions
            )])]
        }
        return steps.enumerated().map { index, step in
            (index, step, findings(step: step, recipe: context, safetyField: safetyFields[index]))
        }
    }

    // MARK: Classification

    /// Classifies a step for strict verification. Reheating overrides the
    /// product class: a reheating step binds to the reheating-topic rule
    /// (165 °F) regardless of the food's raw class.
    func classify(step: String, recipe: String, lookup: DonenessLookup) -> StepContext {
        let loweredStep = step.lowercased()
        let thawingStep = Self.matches(Self.thawWordPattern, in: loweredStep)
        let reheatVerb = Self.matches(Self.reheatVerbPattern, in: loweredStep)
        // "Microwave" alone is also a safe thaw method: a thaw word demotes
        // the appliance word from the reheat indicators, so "defrost in the
        // microwave" stays a thawing step.
        let reheatIndicator = reheatVerb || loweredStep.contains("microwave")

        // Reheating: a reheat indicator over leftover-ish food or a protein.
        let speciesMatch = lookup.check(text: step).map { $0.rule.topic != .reheating } ?? false
        let reheatable = Self.matches(Self.reheatableFoodPattern, in: loweredStep) || speciesMatch
        if reheatIndicator && reheatable && !(thawingStep && !reheatVerb) {
            if let match = lookup.matches(text: step).first(where: { $0.rule.topic == .reheating }) {
                return .reheating(match)
            }
        }

        // Thawing steps carry no doneness requirement (the legacy layer flags
        // ambient thawing).
        if thawingStep {
            return .thawing
        }

        // Protein cooking: a cooking verb plus a protein class from the step,
        // or — when the step names no protein — from the recipe context,
        // unless the step cooks a named non-protein object (stock, rice…).
        if Self.matches(Self.cookingVerbPattern, in: loweredStep) {
            // A bare cooking-verb keyword ("bake" in the casserole list names
            // dishes like an egg bake) binds a protein class only when the
            // step or recipe also names a protein — otherwise "Bake the
            // bread at 400 °F" would fabricate one from how the food cooks.
            let verbOnly: (DonenessMatch) -> Bool = { match in
                DonenessLookup.isBareCookingVerbKeyword(match.matchedKeyword)
                    && !DonenessLookup.mentionsProtein(step)
                    && !DonenessLookup.mentionsProtein(recipe)
            }
            if let match = lookup.check(text: step), !verbOnly(match) {
                return .cooking(match)
            }
            if let match = lookup.check(text: recipe), !verbOnly(match),
               !Self.matches(Self.cookedObjectStopPattern, in: loweredStep) {
                return .cooking(match)
            }
        }
        return .other
    }

    // MARK: Per-step verification against the applicable rule

    /// Verifies one cooking or reheating step against its applicable rule's
    /// check (minimums and rest are read from the rulebook data).
    private func verify(step: String, match: DonenessMatch, rulebook: Rulebook) -> [LintFinding] {
        let rule = match.rule
        guard let check = rule.check else {
            return [LintFinding(
                kind: .failClosed, ruleID: rule.id, phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "",
                detail: "rule \(rule.id) matched the step but carries no thermometer check — the rulebook is incomplete",
                currentText: step
            )]
        }
        let lowered = step.lowercased()
        let temps = Self.parseTempMentions(step)
        let internalTemps = temps.filter { !$0.isDevice }
        let deviceTemps = temps.filter { $0.isDevice }
        let thermometer = Self.matches(Self.thermometerWordPattern, in: lowered)
        let statedRest = Self.statedRestMinutes(step)
        let restRequired = check.restMinutes > 0
        let belowMinimum = internalTemps.first { !Self.meetsMinimum($0, check: check) }
        let tempOK = !internalTemps.isEmpty && belowMinimum == nil
        let restOK = !restRequired || (statedRest ?? 0) >= check.restMinutes
        let validCheck = thermometer && tempOK && restOK

        var found: [LintFinding] = []
        let src = attribution(rule: rule, rulebook: rulebook)
        let minimum = "the class minimum \(Int(check.tempF)) °F (\(Int(check.tempC)) °C)"
        let placement = check.placement.map { $0 } ?? "the thickest part"
        let rewriteHead = "Cook until \(placement) reaches \(Int(check.tempC)) °C (\(Int(check.tempF)) °F) on a food thermometer"
        let rewriteTail = " (Source: \(src.0), \(src.1), retrieved \(rulebook.retrieved))"

        if let cold = belowMinimum {
            // The ground-poultry-160 error class and its relatives: a stated
            // internal temperature below the class minimum, per unit (stated
            // °F compares to the rule's temp_f, stated °C to its temp_c).
            found.append(LintFinding(
                kind: .belowMinimumTemperature,
                ruleID: rule.id,
                phrase: cold.text,
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead) — \(cold.text) is below \(minimum).\(rewriteTail)",
                detail: "\(cold.text) is below \(minimum) for \(rule.foodClass?.rawValue ?? "this class") (rule \(rule.id))",
                currentText: step
            ))
        } else if tempOK && !thermometer {
            // At or above the minimum, but the text never names a thermometer.
            found.append(LintFinding(
                kind: .missingThermometer,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead) — a stated temperature counts only when a thermometer verifies it.\(rewriteTail)",
                detail: "an internal temperature at or above the minimum is stated, but no food thermometer is named in the text",
                currentText: step
            ))
        } else if thermometer && tempOK && restRequired && !restOK {
            found.append(LintFinding(
                kind: .missingRestTime,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead), then rest at least \(Int(check.restMinutes)) minutes.\(rewriteTail)",
                detail: "the class requires a \(Int(check.restMinutes))-minute rest (rule \(rule.id)) that the text does not state\(statedRest.map { " (it states \(Int($0)) minutes)" } ?? "")",
                currentText: step
            ))
        } else if thermometer && internalTemps.isEmpty {
            found.append(LintFinding(
                kind: .missingInternalTemperature,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead).\(rewriteTail)",
                detail: "a thermometer is named but no internal temperature is stated — the check does not count without one",
                currentText: step
            ))
        } else if !thermometer && internalTemps.isEmpty,
                  deviceTemps.isEmpty || !Self.matches(Self.donenessClaimPattern, in: lowered) {
            found.append(LintFinding(
                kind: .missingInternalTemperature,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead).\(rewriteTail)",
                detail: deviceTemps.isEmpty
                    ? "the step cooks \(match.matchedKeyword) but states no thermometer, no internal temperature and no check of any kind"
                    : "\(deviceTemps.first?.text ?? "an oven, pan or microwave temperature") is not an internal reading — the step cooks \(match.matchedKeyword) with no thermometer-named check",
                currentText: step
            ))
        }

        // Clause 4: an oven/pan/microwave temperature never counts as doneness.
        if !deviceTemps.isEmpty, Self.matches(Self.donenessClaimPattern, in: lowered), !validCheck {
            found.append(LintFinding(
                kind: .ovenTemperatureAsDoneness,
                ruleID: rule.id,
                phrase: deviceTemps.first?.text ?? "",
                sourceAttribution: src.0,
                sourceURL: src.1,
                sourceQuote: src.2,
                suggestedTempF: check.tempF,
                suggestedRewrite: "\(rewriteHead) — the \(deviceTemps.first?.text ?? "oven temperature") decides nothing about doneness.\(rewriteTail)",
                detail: "\(deviceTemps.first?.text ?? "an oven/pan temperature") is an oven, pan or microwave temperature — it never counts as an internal doneness check",
                currentText: step
            ))
        }
        return found
    }

    private func attribution(rule: Rule, rulebook: Rulebook) -> (attribution: String, url: String, quote: String) {
        let citation = rulebook.citations(for: rule).first
        return (citation?.attribution ?? "", citation?.url ?? "", citation?.quotes.first ?? "")
    }

    // MARK: Clause 5 — structured safety metadata

    /// Verifies the record's structured safety field against the rulebook and
    /// the instruction text (clause 5): the values are metadata; the text the
    /// user reads must show the check. Unparseable fields, unknown classes and
    /// understated minimums fail closed.
    private func verifySafetyField(_ data: Data, step: String, rulebook: Rulebook, lookup: DonenessLookup, textCheckValid: Bool) -> [LintFinding] {
        func closed(_ detail: String) -> [LintFinding] {
            [LintFinding(
                kind: .failClosed, ruleID: "", phrase: "",
                sourceAttribution: "", sourceURL: "", sourceQuote: "",
                suggestedRewrite: "", detail: detail, currentText: step
            )]
        }
        guard let record = Self.parseSafetyField(data) else {
            return closed("the record's structured safety field could not be parsed as {\"class\", \"temp_f\", \"method\", \"source\"} — the record is unparseable")
        }
        guard let foodClass = FoodClass(rawValue: record.className) else {
            return closed("the record's safety field names food class '\(record.className)', which is not one of the eight FSIS classes — cannot verify, failing closed")
        }
        guard let rule = lookup.rule(for: foodClass), let check = rule.check else {
            return closed("the rulebook defines no thermometer check for class \(record.className) — cannot verify, failing closed")
        }
        guard record.method == "thermometer" else {
            return closed("the record's safety field claims method '\(record.method)' — only a thermometer check can count toward doneness")
        }
        guard !record.source.isEmpty else {
            return closed("the record's safety field carries no source attribution")
        }
        let src = attribution(rule: rule, rulebook: rulebook)
        if record.tempF < check.tempF - 0.05 {
            return [LintFinding(
                kind: .belowMinimumTemperature,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.attribution,
                sourceURL: src.url,
                sourceQuote: src.quote,
                suggestedTempF: check.tempF,
                suggestedRewrite: "Record the check as \(Int(check.tempC)) °C (\(Int(check.tempF)) °F) on a food thermometer and show it in the instruction text — \(record.tempF) °F is below the \(record.className) minimum. (Source: \(src.attribution), \(src.url), retrieved \(rulebook.retrieved))",
                detail: "the record's safety field states \(record.tempF) °F for class \(record.className), below the rulebook minimum \(Int(check.tempF)) °F (rule \(rule.id))",
                currentText: step
            )]
        }
        // The metadata claims a valid thermometer check; the text must show it.
        if !textCheckValid {
            return [LintFinding(
                kind: .metadataNotInText,
                ruleID: rule.id,
                phrase: "",
                sourceAttribution: src.attribution,
                sourceURL: src.url,
                sourceQuote: src.quote,
                suggestedTempF: check.tempF,
                suggestedRewrite: "Cook until \(check.placement.map { $0 } ?? "the thickest part") reaches \(Int(check.tempC)) °C (\(Int(check.tempF)) °F) on a food thermometer\(check.restMinutes > 0 ? ", then rest at least \(Int(check.restMinutes)) minutes" : "") — write the check the record's safety field claims into the instruction text. (Source: \(src.attribution), \(src.url), retrieved \(rulebook.retrieved))",
                detail: "the record's safety field states class \(record.className) at \(record.tempF) °F by thermometer (source: \(record.source)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass",
                currentText: step
            )]
        }
        return []
    }

    /// Whether the step text carries a check that counts (clauses 1–3) under
    /// the context's applicable rule.
    private func textHasValidCheck(_ step: String, context: StepContext) -> Bool {
        switch context {
        case .cooking(let match), .reheating(let match):
            guard let check = match.rule.check else { return false }
            let temps = Self.parseTempMentions(step)
            let internalTemps = temps.filter { !$0.isDevice }
            let thermometer = Self.matches(Self.thermometerWordPattern, in: step.lowercased())
            let restRequired = check.restMinutes > 0
            let statedRest = Self.statedRestMinutes(step)
            return thermometer
                && !internalTemps.isEmpty
                && internalTemps.allSatisfy { Self.meetsMinimum($0, check: check) }
                && (!restRequired || (statedRest ?? 0) >= check.restMinutes)
        case .thawing, .other:
            return false
        }
    }

    // MARK: Detection vocabulary (linter-level; minimums, rest requirements
    // and class keywords all come from the rulebook data)

    /// Cooking verbs — heat applied to food.
    static let cookingVerbPattern =
        #"\b(?:cook|cooks|cooked|cooking|bake|bakes|baked|baking|roast|roasts|roasted|roasting|grill|grills|grilled|grilling|broil|broils|broiled|broiling|fry|fries|fried|frying|sauté|sautés|sautéed|saute|sautes|sear|sears|seared|searing|boil|boils|boiled|boiling|poach|poaches|poached|poaching|simmer|simmers|simmered|simmering|braise|braises|braised|braising|steam|steams|steamed|steaming|scramble|scrambles|scrambled|barbecue|chargrill|blacken|blackened|deep.?fry|stir.?fry|pan.?fry|air.?fry|microwave|microwaves|microwaved|reheat|reheats|reheated|reheating)\b"#

    /// Reheat verbs beyond the appliance itself.
    static let reheatVerbPattern = #"\b(?:reheat|reheats|reheated|reheating|re-warm|rewarm|warm up|warming up|warm through|warm the|warm it|warm them)\b"#

    static let thawWordPattern = #"\b(?:thaw|thaws|thawing|thawed|defrost|defrosts|defrosting|defrosted)\b"#

    /// Foods whose reheating must reach the reheating rule's minimum:
    /// leftovers and leftover-like dishes.
    static let reheatableFoodPattern =
        #"\b(?:leftovers?|left[- ]?overs?|cooked (?:rice|pasta|chicken|meat|fish|food|dish|meal)|sauce|soup|gravy|stew|casserole|curry|chilli|chili|chowder|rice|pasta|noodles?|pizza|pie)\b"#

    /// Non-protein cooked objects: when a step names one, the recipe's protein
    /// context does not put the step under a doneness requirement (simmering
    /// stock in a chicken recipe is not cooking chicken).
    static let cookedObjectStopPattern =
        #"\b(?:stock|broth|water|wine|beer|rice|pasta|noodles?|lentils?|beans?|quinoa|couscous|oats|porridge|vegetables?|onions?|garlic|potato(?:es)?|sauce|syrup|cream|milk|butter|oil|dough|bread|gravy)\b"#

    /// Vague or appearance doneness claims — the clause-4 trigger when the only
    /// temperature around is an oven/pan/microwave one.
    static let donenessClaimPattern =
        #"(?:until|till)\s+(?:it(?:'s| is)?\s+|they(?:'re| are)?\s+|everything is\s+)?(?:fully\s+|completely\s+)?(?:done|cooked|cooked through|safe to eat)|cooked through|no longer pink|no pink|not pink|juices? (?:run|runs) clear|clear juices|no longer translucent|browned through|firm to the touch|golden|opaque"#

    /// Thermometer words (contract clause 1): thermometer, instant-read
    /// thermometer, meat/food thermometer, probe — plus reasonable synonyms.
    static let thermometerWordPattern = #"\bthermomet(?:er|re)s?\b|\binstant[- ]read\b|\bprobe\b"#

    /// A temperature statement: number(s) with an explicit °F/°C unit. Ranges
    /// ("140–145°F") yield both bounds — a range whose low end sits below the
    /// class minimum instructs undercooking. Unitless numbers never count.
    static let tempPattern =
        #"(\d+(?:[.,]\d+)?)(?:\s*(?:–|—|-|to)\s*(\d+(?:[.,]\d+)?))?\s*(?:°\s*([cf])\b|deg(?:rees?)?\.?\s+([cf])(?:elsius|ahrenheit|renheit)?\b)"#

    static func parseTempMentions(_ text: String) -> [TempMention] {
        var mentions: [TempMention] = []
        let nsText = text.lowercased() as NSString
        for sentence in Self.sentences(in: text) {
            let lowered = sentence.lowercased() as NSString
            guard let regex = try? NSRegularExpression(pattern: tempPattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: lowered as String, options: [], range: NSRange(location: 0, length: lowered.length)) {
                let unitRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 4)
                guard unitRange.length > 0, match.range(at: 1).length > 0,
                      let first = Double(lowered.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")) else { continue }
                let unitLetter = lowered.substring(with: unitRange).lowercased()
                let unit: TempMention.Unit = unitLetter.hasPrefix("c") ? .celsius : .fahrenheit
                var bounds: [Double] = [first]
                if match.range(at: 2).length > 0,
                   let second = Double(lowered.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: ".")) {
                    bounds.append(second)
                }
                let window = lowered.substring(to: match.range.upperBound)
                let sentenceText = lowered as String
                let isDevice = Self.tempIsDevice(window: window, sentence: sentenceText)
                let mentionText = lowered.substring(with: match.range)
                for value in bounds {
                    mentions.append(TempMention(value: value, unit: unit, isDevice: isDevice, text: mentionText))
                }
            }
        }
        _ = nsText // (kept for symmetry; sentences cover the whole text)
        return mentions
    }

    static func sentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Attributes a temperature mention inside a sentence: a strong device cue
    /// (oven, oil, pan, fryer, microwave, preheat…) anywhere in the window
    /// before the temperature marks it as a device temperature; otherwise the
    /// closest cue before the temperature decides; an uncued temperature is
    /// read as the food's internal temperature (the fail-closed direction).
    static func tempIsDevice(window: String, sentence: String) -> Bool {
        let strongDevice = #"\b(?:oven|preheat\w*|oil|fat|pan|skillet|wok|frying|deep.?fry|air.?fry|fryer|microwave\w*|slow.?cook\w*|crock.?pot|pressure.?cook\w*|sous.?vide|griddle|burner|hotplate|hob|dial)\b"#
        let weakDevice = #"\b(?:bake|bakes|baked|baking|roast|roasts|roasted|roasting|grill|grills|grilled|grilling|broil|broils|broiled|broiling|heat|heats|heated|heating)\b"#
        let internalCue = #"\b(?:internal temperature|internal temp|thermomet\w+|instant[- ]read|probe|reads?|reading|registers?|registered?|reaches?|reached|insert\w*|cook to|cooks to|cooked to|bring to|brought to|until (?:it|the|they)|centre|center|thickest|middle|thigh|wing|breast|joint|part|done)\b"#

        // The cue nearest the temperature decides (later cue wins): a device
        // cue earlier in the sentence ("sear the chops in a pan, then cook
        // to 145 °F") does not turn the stated temperature into a pan
        // temperature, and "heat the oil to 350 °F" stays an oil temperature.
        let cues: [(device: Bool, end: Int)] = [
            Self.lastCueEnd(strongDevice, in: window).map { (true, $0) },
            Self.lastCueEnd(internalCue, in: window).map { (false, $0) },
            Self.lastCueEnd(weakDevice, in: window).map { (true, $0) },
        ].compactMap { $0 }
        if let latest = cues.max(by: { $0.end < $1.end }) {
            return latest.device
        }
        // No cue before the temperature: an appliance word anywhere in the
        // sentence ("in a 350 °F oven") marks it; otherwise it is the food's
        // internal temperature (the fail-closed direction).
        return matches(strongDevice, in: sentence)
    }

    static func lastCueEnd(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var last: Int?
        for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
            last = match.range.upperBound
        }
        return last
    }

    /// Whether a stated internal temperature meets the rule's class minimum.
    /// Each unit compares against the rulebook's own published pair (temp_f
    /// and temp_c), never a hardcoded table.
    static func meetsMinimum(_ mention: TempMention, check: DonenessCheck) -> Bool {
        switch mention.unit {
        case .fahrenheit: return mention.value >= check.tempF - 0.05
        case .celsius: return mention.value >= check.tempC - 0.05
        }
    }

    /// The rest time the step text states, in minutes (nil when none). Rest
    /// and standing wording, digits or common number words, minutes or hours.
    static func statedRestMinutes(_ text: String) -> Double? {
        let wordNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45]
        // A rest word not preceded by "the " (which reads as "the rest of the
        // stock"), followed by a duration.
        let restWordPattern = #"(?<!the )\brest(?:s|ing|ed)?\b|(?<!the )\bstand(?:s|ing)?\b"#
        if let regex = try? NSRegularExpression(pattern: restWordPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
                guard let afterRange = Range(NSRange(location: match.range.upperBound, length: max(text.count - match.range.upperBound, 0)), in: text) else { continue }
                let after = String(text[afterRange]).prefix(60)
                if let duration = Self.durationMinutes(String(after), wordNumbers: wordNumbers) {
                    return duration
                }
            }
        }
        // Reversed: "3 minutes rest".
        if let regex = try? NSRegularExpression(pattern: #"\b(\d+|one|two|three|four|five|ten|fifteen|twenty|thirty|forty[- ]?five)\s*(?:minutes?|mins?|hours?|hrs?)\b[^.]{0,20}\brest"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let numberRange = Range(match.range(at: 1), in: text) {
            let word = String(text[numberRange]).lowercased()
            let value = wordNumbers[word].map(Double.init) ?? Double(word) ?? 0
            let matchedText = Range(match.range, in: text).map { String(text[$0]) } ?? ""
            let isHours = Self.matches(#"hours?|hrs?"#, in: matchedText)
            return isHours ? value * 60 : value
        }
        return nil
    }

    static func durationMinutes(_ text: String, wordNumbers: [String: Int]) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty[- ]?five)\s*(minutes?|mins?|hours?|hrs?)\b"#, options: [.caseInsensitive]) else { return nil }
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let word = String(text[numberRange]).lowercased()
        let value = wordNumbers[word].map(Double.init) ?? Double(word.replacingOccurrences(of: ",", with: ".")) ?? 0
        let unit = String(text[unitRange]).lowercased()
        if unit.hasPrefix("h") { return value * 60 }
        return value
    }

    // MARK: Structured safety field parsing

    struct SafetyFieldRecord: Equatable, Sendable {
        let className: String
        let tempF: Double
        let method: String
        let source: String
    }

    /// Parses the corpus safety field shape: `{"class": <food_class>,
    /// "temp_f": N, "method": "thermometer", "source": <title + URL>}`.
    /// Returns nil when unparseable (the caller fails closed).
    static func parseSafetyField(_ data: Data) -> SafetyFieldRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let allowed = ["class", "temp_f", "method", "source"]
        guard Set(object.keys) == Set(allowed),
              let className = object["class"] as? String,
              let tempF = (object["temp_f"] as? Double) ?? ((object["temp_f"] as? Int).map(Double.init)),
              let method = object["method"] as? String,
              let source = object["source"] as? String else {
            return nil
        }
        return SafetyFieldRecord(className: className, tempF: tempF, method: method, source: source)
    }
}

/// One parsed temperature statement: the value, its unit, whether it belongs
/// to an oven/pan/microwave (device) rather than the food's interior, and the
/// verbatim text it was parsed from.
public struct TempMention: Equatable, Sendable {
    public enum Unit: String, Sendable { case fahrenheit, celsius }

    public let value: Double
    public let unit: Unit
    public let isDevice: Bool
    public let text: String

    public init(value: Double, unit: Unit, isDevice: Bool, text: String) {
        self.value = value
        self.unit = unit
        self.isDevice = isDevice
        self.text = text
    }
}
