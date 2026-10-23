import Foundation

/// A doneness rule matched to a text (ingredient name or recipe step).
public struct DonenessMatch: Equatable, Sendable {
    public let rule: Rule
    /// The keyword that matched, for explainability.
    public let matchedKeyword: String
    /// Selection rank of the winning keyword (lower = more specific context).
    let matchTier: Int

    public init(rule: Rule, matchedKeyword: String) {
        self.rule = rule
        self.matchedKeyword = matchedKeyword
        self.matchTier = 2
    }

    init(rule: Rule, matchedKeyword: String, matchTier: Int) {
        self.rule = rule
        self.matchedKeyword = matchedKeyword
        self.matchTier = matchTier
    }
}

/// Looks up the applicable doneness check for an ingredient or recipe step.
/// Matching is whole-word, case-insensitive. When several rules match, the
/// most specific context wins: processing form first ("ground pork" is
/// ground, not whole cut), then the species word ("tuna steak" is fish, not a
/// beef steak), then generic cut words. Pantry compounds whose food word
/// names a product rather than the thing being cooked ("fish sauce",
/// "chicken stock") never match.
public struct DonenessLookup {
    private let donenessRules: [Rule]

    public init(rulebook: Rulebook) {
        // Rules with keywords and a thermometer check, in file order; the
        // lookup ranks candidates by matched-keyword specificity.
        donenessRules = rulebook.rules.filter { $0.check != nil && $0.matchKeywords != nil }
    }

    /// The doneness rule for a class, if the rulebook defines one.
    public func rule(for foodClass: FoodClass) -> Rule? {
        donenessRules.first { $0.foodClass == foodClass }
    }

    public func check(text: String) -> DonenessMatch? {
        let folded = Self.neutraliseCompounds(text.lowercased())
        var best: DonenessMatch?
        for rule in donenessRules {
            for keyword in rule.matchKeywords ?? [] where Self.matches(keyword: keyword, in: folded) {
                let tier = Self.tier(for: keyword)
                let better: Bool
                if let current = best {
                    if tier != current.matchTier {
                        better = tier < current.matchTier
                    } else {
                        better = keyword.count > current.matchedKeyword.count
                    }
                } else {
                    better = true
                }
                if better {
                    best = DonenessMatch(rule: rule, matchedKeyword: keyword, matchTier: tier)
                }
            }
        }
        // Poultry processed as mince keeps the poultry minimum: FSIS publishes
        // ground poultry separately, and meat_ground's 160 °F would understate
        // it (the corpus must cite meat_poultry for ground poultry too).
        if best?.rule.foodClass == .meatGround,
           Self.matchesPoultrySpecies(folded),
           let groundPoultry = donenessRules.first(where: { $0.id == "ground-poultry-165" }) {
            best = DonenessMatch(rule: groundPoultry, matchedKeyword: "ground poultry", matchTier: 0)
        }
        return best
    }

    /// Words that state how the protein was processed — they decide the class
    /// over anything else ("ground pork" is meat_ground even though "pork"
    /// also matches).
    static let processingWords: Set<String> = [
        "ground", "minced", "mince", "diced", "shredded", "burger", "patty", "patties",
    ]

    /// Species words — more specific than the cut they come from ("tuna
    /// steak" resolves to fish, not to the beef steak rule).
    static let speciesWords: Set<String> = [
        "chicken", "turkey", "duck", "goose", "quail", "beef", "pork", "lamb",
        "veal", "venison", "mutton", "goat", "ham", "gammon", "bacon",
        "salmon", "cod", "tuna", "trout", "haddock", "pollock", "catfish",
        "bass", "mackerel", "sardine", "sardines", "anchovy", "halibut",
        "shrimp", "prawn", "prawns", "mussel", "mussels", "clam", "clams",
        "oyster", "oysters", "scallop", "scallops", "crab", "lobster",
        "squid", "octopus", "cockles", "egg", "eggs", "yolk", "yolks",
        "leftover", "leftovers",
    ]

    /// Selection precedence: 0 beats 1 beats 2.
    static func tier(for keyword: String) -> Int {
        let words = Set(keyword.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: processingWords) { return 0 }
        if !words.isDisjoint(with: speciesWords) { return 1 }
        return 2
    }

    /// Doneness keywords that are bare cooking-verb forms — "bake" in the
    /// casserole list names dishes like an egg bake, not the imperative. A
    /// bare verb binds a protein class only when the text also names a
    /// protein, so "Bake the bread at 400 °F" cannot fabricate one.
    static let bareVerbKeywordPattern = "^(?:bake|roast|grill|broil|fry|heat|cook)(?:s|ed|ing)?$"

    static func isBareCookingVerbKeyword(_ keyword: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: bareVerbKeywordPattern) else { return false }
        let range = NSRange(keyword.startIndex..., in: keyword)
        return regex.firstMatch(in: keyword, range: range) != nil
    }

    /// Species whose processed form keeps the poultry minimum (165 °F), not
    /// the generic ground-meat 160 °F.
    static let poultrySpecies: Set<String> = ["chicken", "turkey", "duck", "goose", "quail", "hen"]

    static func matchesPoultrySpecies(_ foldedText: String) -> Bool {
        poultrySpecies.contains { matches(keyword: $0, in: foldedText) }
    }

    /// All rules whose keywords match the text, most specific first (tier,
    /// then longer keyword, then rulebook order). Includes the ground-poultry
    /// override when the text names poultry processed as mince. Deterministic.
    public func matches(text: String) -> [DonenessMatch] {
        let folded = Self.neutraliseCompounds(text.lowercased())
        var candidates: [(match: DonenessMatch, order: Int)] = []
        for (order, rule) in donenessRules.enumerated() {
            for keyword in rule.matchKeywords ?? [] where Self.matches(keyword: keyword, in: folded) {
                candidates.append((DonenessMatch(rule: rule, matchedKeyword: keyword, matchTier: Self.tier(for: keyword)), order))
            }
        }
        // Poultry processed as mince keeps the poultry minimum: add the
        // ground-poultry rule when a ground match and a poultry species both
        // appear (the same override `check(text:)` applies).
        if candidates.contains(where: { $0.match.rule.foodClass == .meatGround }),
           Self.matchesPoultrySpecies(folded),
           let groundPoultry = donenessRules.first(where: { $0.id == "ground-poultry-165" }) {
            candidates.append((DonenessMatch(rule: groundPoultry, matchedKeyword: "ground poultry", matchTier: 0), -1))
        }
        return candidates.sorted { lhs, rhs in
            if lhs.match.matchTier != rhs.match.matchTier { return lhs.match.matchTier < rhs.match.matchTier }
            if lhs.match.matchedKeyword.count != rhs.match.matchedKeyword.count { return lhs.match.matchedKeyword.count > rhs.match.matchedKeyword.count }
            return lhs.order < rhs.order
        }.map { $0.match }
    }

    /// Generic protein words beyond the class keywords — meats, seafood and
    /// processed meats the rulebook may not classify. A cooking step naming
    /// one of these with no resolvable class is flagged for review, never
    /// passed (contract clause 6).
    static let genericProteinWords: Set<String> = [
        "meat", "meats", "seafood", "offal", "rabbit", "hare", "venison",
        "bison", "buffalo", "boar", "ostrich", "emu", "kangaroo", "crocodile",
        "alligator", "frog", "snail", "snails", "escargot", "liver", "kidney",
        "tongue", "tripe", "sweetbread", "sweetbreads", "sausage", "sausages",
        "bratwurst", "kielbasa", "chorizo", "salami", "pepperoni", "prosciutto",
        "pancetta", "mortadella", "bologna", "frankfurter", "frankfurters",
        "hot dog", "hot dogs", "deli meat", "deli meats", "lunch meat",
        "cold cuts", "pheasant", "partridge", "grouse", "pigeon", "squab",
        "moose", "elk", "caribou", "reindeer", "squirrel",
    ]

    /// Whole-word protein mention (species or generic words), with pantry
    /// compounds neutralised so "fish sauce" never reads as fish.
    static func mentionsProtein(_ text: String) -> Bool {
        let folded = neutraliseCompounds(text.lowercased())
        let words = genericProteinWords.union(speciesWords)
        return words.contains { matches(keyword: $0, in: folded) }
    }

    /// Pantry compounds where the food word names a product, not the protein
    /// being cooked — matching them would fabricate a doneness class.
    static let compoundExclusions = [
        "fish sauce", "fish stock", "chicken stock", "beef stock", "beef broth",
        "bone broth", "ham stock", "meat tenderiser", "meat tenderizer",
        "meat thermometer", "meat thermometre",
    ]

    static func neutraliseCompounds(_ text: String) -> String {
        var out = text
        for compound in compoundExclusions {
            out = out.replacingOccurrences(of: compound, with: compound.replacingOccurrences(of: " ", with: ""))
        }
        return out
    }

    /// Whole-word, adjacency-preserving match. Multi-word keywords allow
    /// whitespace between tokens; \b boundaries stop "egg" matching "eggplant".
    static func matches(keyword: String, in foldedText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: keyword.lowercased())
        let pattern = "\\b" + escaped.replacingOccurrences(of: "\\ ", with: " ") + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: " ", with: "\\s+")) else {
            return foldedText.contains(keyword.lowercased())
        }
        return regex.firstMatch(in: foldedText, range: NSRange(foldedText.startIndex..., in: foldedText)) != nil
    }
}
