import Foundation
import FLTaste
import FLTasteSim

/// Independent, fail-closed restriction evaluation of ranked recipes.
///
/// Deliberately NOT a restatement of Sim's feasible-set filter
/// (`Pantry.isLegal`): that filter matches allergies by exact ingredient
/// id, trusts diet tags as shipped, and silently passes unknown restriction
/// targets. Zero membership violations therefore does not establish zero
/// unsafe suggestions — an allergen hiding inside a compound ingredient or
/// an unrecognized restriction target sails through the filter unchecked.
/// This evaluator re-derives expectations from the household's declared
/// restrictions and the catalog's own data, with unverifiable treated as
/// unsafe:
///
/// - an allergy blocks its `RecipeCatalog.blockedIngredients` expansion
///   PLUS any ingredient whose id or NAME's head token matches the
///   target's token stem ("peanut_oil" under a "peanuts" allergy);
///   head-token matching keeps "peanut butter" from matching a dairy
///   "butter" allergy while still catching allergen-headed compounds,
/// - a diet requires the matching tag on the recipe itself,
/// - an unresolvable restriction target, an unknown recipe id, or an
///   unknown ingredient id is unverifiable and counts as a violation.
///
/// The violation surface is the shown slate — what the household could
/// actually pick — not the internal candidate order. Strict-side errors
/// only: a false positive over-states violations (never hides one), which
/// is the safe bias for a safety bar. Full ingredient-graph composition
/// analysis is FLIngredientFacts' remit (PR #127); this check is
/// self-contained so suite B owns its own safety claim.
struct RestrictionExpectations: Sendable {
    /// One declared restriction, with the week it became binding.
    struct Rule: Sendable {
        var startWeek: Int
        var kind: Restriction.Kind
        var target: String
    }

    private let rules: [Rule]
    private let catalog: RecipeCatalog

    /// Direct init for tests and callers that hold declared rules already.
    init(rules: [Rule], catalog: RecipeCatalog) {
        self.rules = rules
        self.catalog = catalog
    }

    init(household: Household, shifts: [GroundTruth.ShiftRecord], catalog: RecipeCatalog) {
        var rules = household.restrictionUnion.map {
            Rule(startWeek: 0, kind: $0.kind, target: $0.target)
        }
        // A diet shift adds its restriction to the household union from the
        // shift's week on (SimConfig.ShiftSpec semantics).
        for shift in shifts where shift.kind == "diet" {
            guard let diet = shift.detail["diet"] else { continue }
            rules.append(Rule(startWeek: shift.week, kind: .diet, target: diet))
        }
        self.init(rules: rules, catalog: catalog)
    }

    /// Violations among the slate recipes ranked for a session in `week`.
    /// `neverSuggest` is the running set of never-suggest ingredient ids
    /// the household has emitted so far (exact-id per Sim semantics — a
    /// preference edit, not a safety restriction).
    func violations(
        week: Int, slate: [RecipeID], neverSuggest: Set<IngredientID>
    ) -> Int {
        let active = rules.filter { week >= $0.startWeek }
        guard !active.isEmpty || !neverSuggest.isEmpty else { return 0 }

        let allergenTargets = active.filter { $0.kind == .allergy }
        let dietTargets = active.filter { $0.kind == .diet }

        // Resolve allergies once per call: the catalog's own expansion plus
        // the head-token net over ids and names.
        var blocked = Set<IngredientID>()
        var unresolved = false
        var stems = Set<String>()
        for target in allergenTargets {
            let expanded = catalog.blockedIngredients(target: target.target)
            if expanded.isEmpty { unresolved = true }
            blocked.formUnion(expanded)
            stems.formUnion(Self.tokens(from: target.target))
        }

        var count = 0
        for recipeID in slate {
            guard let recipe = catalog.recipes[recipeID] else {
                count += 1  // unknown recipe: unverifiable
                continue
            }
            var unsafe = false
            for use in recipe.requiredIngredients + recipe.optionalIngredients {
                if blocked.contains(use.id) || neverSuggest.contains(use.id) {
                    unsafe = true
                }
                guard let ingredient = catalog.ingredients[use.id] else {
                    unresolved = true  // unknown ingredient: unverifiable
                    continue
                }
                // Head-token net: the ingredient's first id token or first
                // name word carrying the allergen stem flags compounds the
                // exact-id expansion misses.
                if !stems.isEmpty && !stems.isDisjoint(with: Self.headTokens(id: ingredient.id.rawValue, name: ingredient.name)) {
                    unsafe = true
                }
            }
            for diet in dietTargets {
                switch diet.target {
                case "vegetarian": if !recipe.hasTag(.vegetarian) { unsafe = true }
                case "vegan": if !recipe.hasTag(.vegan) { unsafe = true }
                default: unresolved = true  // unknown diet: unverifiable
                }
            }
            if unsafe || unresolved { count += 1 }
        }
        return count
    }

    /// Word-boundary tokens from an id or name, crudely singularized, so
    /// "peanuts" yields "peanut" and "egg" never matches "eggplant".
    static func tokens(from source: String) -> Set<String> {
        var tokens = Set<String>()
        for word in source.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var token = String(word)
            if token.count > 3 && token.hasSuffix("s") { token.removeLast() }
            tokens.insert(token)
        }
        return tokens
    }

    /// The head tokens: first id word and first name word (singularized).
    static func headTokens(id: String, name: String) -> Set<String> {
        var tokens = Set<String>()
        if let first = id.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first {
            var token = String(first)
            if token.count > 3 && token.hasSuffix("s") { token.removeLast() }
            tokens.insert(token)
        }
        if let first = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first {
            var token = String(first)
            if token.count > 3 && token.hasSuffix("s") { token.removeLast() }
            tokens.insert(token)
        }
        return tokens
    }
}
