import Foundation
import FLDomain
import FLInventoryCore

// MARK: - Preparation compatibility
// Which preparation forms a line can draw from. Deliberately conservative:
// raw stock can become any knife-work form (chopped, grated, ...); anything
// else ("cooked", "roasted", an unknown word) is exact-match only, because
// assuming a transform the pantry cannot prove would overclaim feasibility.
// A raw line needs raw stock — chopped onions cannot be un-chopped.

public struct FLPreparationTransforms: Hashable, Sendable {
    /// Lowercase preparation forms plain knife/mixer work can produce from raw stock.
    public let knifeWork: Set<String>

    public init(knifeWork: Set<String>) throws {
        var normalized: Set<String> = []
        for raw in knifeWork {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "FLPreparationTransforms.knifeWork", reason: "form names must not be empty")
            }
            normalized.insert(trimmed)
        }
        self.knifeWork = normalized
    }

    /// The standard transforms: plain knife work on raw ingredients.
    public static let standard = try! FLPreparationTransforms(knifeWork: [
        "chopped", "finely chopped", "roughly chopped", "sliced", "diced",
        "minced", "grated", "shredded", "julienned", "torn",
    ])

    private static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Can a lot in `lotPreparation` (nil = raw) serve a line asking for
    /// `linePreparation` (nil = raw)?
    public func lotUsable(forLine linePreparation: String?, lotPreparation: String?) -> Bool {
        let line = Self.normalize(linePreparation)
        let lot = Self.normalize(lotPreparation)
        guard let line else { return lot == nil } // a raw line needs raw stock
        if line == lot { return true }            // already in the asked form
        return lot == nil && knifeWork.contains(line) // raw stock, knife-work form
    }
}

// MARK: - The feasibility engine
// Pure and deterministic: (recipe, stock snapshot, restrictions) → report.
// Allocation is SEQUENTIAL over required lines in recipe order against one
// working pool, so the same ingredient on two lines cannot double-count one
// lot (SPEC 3.2). Only satisfied lines reserve stock; a short line consumes
// what it shows (the cook uses it and tops up the shortfall), so later lines
// of the same ingredient see the true remainder.
//
// Line-state order of questions, each with a test:
// 1. Does a hard restriction forbid it? → blockedByRestriction
// 2. Is there a stock group for the identity at all? → missing
// 3. Do any of its lots come in a usable form? → missing (form reason)
// 4. Is the required amount known? → uncertainStock
// 5. Is the usable stock fully counted? → uncertainStock
// 6. Do the known grams cover the requirement? → satisfied / short / missing

public enum FLPantryFeasibility {
    /// One working lot: identity of the source lot, its form, what
    /// remains (nil = uncounted), and when the shelf last confirmed it.
    private struct PoolLot {
        let lotID: String
        let preparation: String?
        var remainingGrams: Double?
        let lastConfirmedAt: Date?
    }

    /// An accepted substitution the fit may use: the line's ingredient
    /// identity group, the substitute, and the mass conversion (substitute
    /// grams per asked-for gram). The caller owns the acceptance and the
    /// conversion evidence; feasibility only applies them. Pure data — no
    /// catalog lookups, no network (SPEC 3.2: fit over "accepted swaps").
    public struct FLAcceptedSwap: Hashable, Sendable {
        /// The identity group the swap replaces (see `FLStockFold.groupKey`).
        public let replacesGroupKey: String
        /// The substitute identity the pantry may draw instead.
        public let substitute: IngredientReference
        /// Substitute grams per asked-for gram. Must be finite and > 0.
        public let gramsFactor: Double

        public init(replacesGroupKey: String, substitute: IngredientReference, gramsFactor: Double) throws {
            let trimmedKey = replacesGroupKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                throw FLDomainError.validation(target: "FLAcceptedSwap.replacesGroupKey", reason: "must not be empty")
            }
            guard gramsFactor.isFinite, gramsFactor > 0 else {
                throw FLDomainError.validation(target: "FLAcceptedSwap.gramsFactor", reason: "must be a finite positive conversion (got \(gramsFactor))")
            }
            self.replacesGroupKey = trimmedKey
            self.substitute = substitute
            self.gramsFactor = gramsFactor
        }
    }

    /// Ingredients assumed present when the pantry has no record at all.
    /// A product default, not evidence — the app may pass its own set.
    public static let defaultStaples: Set<String> = [
        "salt", "black pepper", "water", "olive oil", "vegetable oil",
    ]

    /// Two weeks: the default reconfirm window. Older evidence asks the
    /// cook to look at the shelf ("Still 2 lemons?") before trusting it.
    public static let defaultReconfirmWindow: TimeInterval = 14 * 24 * 60 * 60

    public static func evaluate(
        recipe: RecipeRevision,
        stock: [FLItemStock],
        restriction: Restriction,
        transforms: FLPreparationTransforms = .standard,
        staples: Set<String> = FLPantryFeasibility.defaultStaples,
        swaps: [FLAcceptedSwap] = [],
        targetServings: Int? = nil,
        now: Date = Date(),
        reconfirmWindow: TimeInterval? = FLPantryFeasibility.defaultReconfirmWindow
    ) throws -> FLFeasibilityReport {
        // Servings (SPEC 3.2): the bill is written for the revision's basis;
        // a different target scales every line proportionally.
        let servingsScale = Double(targetServings ?? recipe.servingBasis.servings)
            / Double(recipe.servingBasis.servings)

        // Working pool: group key → lots (oldest first), decremented as
        // satisfied/short lines reserve or consume.
        var pool: [String: [PoolLot]] = [:]
        for item in stock {
            pool[FLStockFold.groupKey(for: item.ingredient)] = item.lots.map { lot in
                PoolLot(
                    lotID: lot.lotID,
                    preparation: lot.preparation,
                    remainingGrams: lot.remaining.gramsIfKnown?.grams,
                    lastConfirmedAt: lot.lastConfirmedAt
                )
            }
        }

        // A pure read of one identity against the current pool: state,
        // numbers, usable lots, freshness. NO mutation — the caller decides
        // what to reserve (a swap probe must never consume stock).
        struct Assessment {
            var state: FLFeasibilityLineState
            var availableGrams: Double?
            var reason: String
            var usableLotIDs: Set<String>
            var stale: Bool
        }

        // Stale evidence (SPEC 3.2 "needs reconfirming"): nothing usable on
        // the shelf was confirmed inside the window. A nil confirmation date
        // is not fresh — evidence without a time cannot be trusted as recent.
        func isStale(_ lots: [PoolLot]) -> Bool {
            guard let window = reconfirmWindow else { return false }
            guard let freshest = lots.compactMap(\.lastConfirmedAt).max() else { return true }
            return freshest < now.addingTimeInterval(-window)
        }

        func assess(ingredient: IngredientReference, requiredGrams: Double?, preparation: String?) -> Assessment {
            let key = FLStockFold.groupKey(for: ingredient)
            let lots = pool[key] ?? []

            // Any lot in a form this line can use?
            let usable = lots.filter { transforms.lotUsable(forLine: preparation, lotPreparation: $0.preparation) }
            let usableIDs = Set(usable.map(\.lotID))
            guard !usable.isEmpty else {
                let forms = Set(lots.compactMap(\.preparation)).sorted().joined(separator: ", ")
                let needForm = preparation ?? "raw"
                let reason = forms.isEmpty
                    ? "'\(ingredient.canonicalName)' is only on the shelf in prepared forms; this line needs it \(needForm)"
                    : "'\(ingredient.canonicalName)' is on the shelf only as \(forms); this line needs it \(needForm)"
                return Assessment(state: .missing, availableGrams: nil, reason: reason, usableLotIDs: usableIDs, stale: false)
            }

            // Is the required amount known? Unknown never becomes a number.
            guard let required = requiredGrams else {
                let counted = usable.compactMap(\.remainingGrams)
                let allCounted = counted.count == usable.count
                let available = allCounted ? counted.reduce(0, +) : nil
                let shelf = available.map { "the shelf shows \(gramsLabel($0))" } ?? "the shelf amount is uncounted"
                return Assessment(
                    state: .uncertainStock,
                    availableGrams: available,
                    reason: "the recipe amount for '\(ingredient.canonicalName)' is unmeasured; \(shelf)",
                    usableLotIDs: usableIDs,
                    stale: false
                )
            }

            // Is the usable stock fully counted?
            let knownGrams = usable.compactMap(\.remainingGrams)
            guard knownGrams.count == usable.count else {
                return Assessment(
                    state: .uncertainStock,
                    availableGrams: nil,
                    reason: "the shelf stock of '\(ingredient.canonicalName)' is uncounted, so \(gramsLabel(required)) cannot be confirmed",
                    usableLotIDs: usableIDs,
                    stale: false
                )
            }

            // Do the known grams cover the requirement?
            let total = knownGrams.reduce(0, +)
            if total >= required {
                return Assessment(
                    state: .satisfied,
                    availableGrams: total,
                    reason: "you have \(gramsLabel(total)), the recipe needs \(gramsLabel(required))",
                    usableLotIDs: usableIDs,
                    stale: isStale(usable)
                )
            } else if total > 0 {
                return Assessment(
                    state: .short,
                    availableGrams: total,
                    reason: "the recipe needs \(gramsLabel(required)), you have \(gramsLabel(total))",
                    usableLotIDs: usableIDs,
                    stale: isStale(usable)
                )
            } else {
                return Assessment(
                    state: .missing,
                    availableGrams: 0,
                    reason: "the recipe needs \(gramsLabel(required)), but no '\(ingredient.canonicalName)' is left",
                    usableLotIDs: usableIDs,
                    stale: false
                )
            }
        }

        // Reserve what a DECIDED line consumes: satisfied lines take FIFO
        // from their usable lots, short lines consume what they show.
        func reserve(_ key: String, usableIDs: Set<String>, satisfiedGrams: Double?) {
            guard var itemLots = pool[key] else { return }
            defer { pool[key] = itemLots }
            if let grams = satisfiedGrams {
                var toTake = grams
                for index in itemLots.indices where usableIDs.contains(itemLots[index].lotID) {
                    guard toTake > 0 else { break }
                    if let remaining = itemLots[index].remainingGrams, remaining > 0 {
                        let taken = min(remaining, toTake)
                        itemLots[index].remainingGrams = remaining - taken
                        toTake -= taken
                    }
                }
            } else {
                for index in itemLots.indices where usableIDs.contains(itemLots[index].lotID) {
                    itemLots[index].remainingGrams = 0
                }
            }
        }

        func buildLine(
            _ lineID: String,
            ingredient: IngredientReference,
            state: FLFeasibilityLineState,
            availableGrams: Double?,
            requiredGrams: Double?,
            reason: String,
            viaSwap: Bool = false
        ) throws -> FLFeasibilityLine {
            try FLFeasibilityLine(
                lineID: lineID,
                state: state,
                ingredient: ingredient,
                availableGrams: availableGrams,
                requiredGrams: requiredGrams,
                reason: reason,
                viaSwap: viaSwap
            )
        }

        func evaluateLine(_ line: IngredientLine) throws -> FLFeasibilityLine {
            let key = FLStockFold.groupKey(for: line.ingredient)

            // 1. Hard restrictions are absolute (SPEC 3.1): the union of the
            // household's restrictions filters candidates; stock, staples
            // and swaps never matter for a forbidden ingredient.
            guard restriction.permits(canonicalName: line.ingredient.canonicalName) else {
                return try buildLine(
                    line.lineID,
                    ingredient: line.ingredient,
                    state: .blockedByRestriction,
                    availableGrams: nil,
                    requiredGrams: line.quantity.gramsIfKnown.map { $0.grams * servingsScale },
                    reason: "'\(line.ingredient.canonicalName)' is excluded by this household's hard restrictions"
                )
            }

            // Servings (SPEC 3.2): lines are written for the revision's
            // basis; a different target scales the bill proportionally.
            let scaledRequired = line.quantity.gramsIfKnown.map { $0.grams * servingsScale }

            // 2. The asked-for identity against the pool. No record at all
            // assesses as missing and may still be rescued by an accepted
            // swap below.
            let hasRecord = !(pool[key] ?? []).isEmpty
            var asked = hasRecord
                ? assess(ingredient: line.ingredient, requiredGrams: scaledRequired, preparation: line.preparation)
                : Assessment(
                    state: .missing,
                    availableGrams: nil,
                    reason: "'\(line.ingredient.canonicalName)' is not on the shelf",
                    usableLotIDs: [],
                    stale: false
                )

            // An accepted swap may cover a line the asked-for identity
            // cannot. Only a full rescue counts, the substitute must pass
            // the same hard restrictions (a swap never feeds the household
            // a forbidden food), and a failed probe reserves nothing.
            if asked.state == .missing,
               let swap = swaps.first(where: { $0.replacesGroupKey == key }),
               restriction.permits(canonicalName: swap.substitute.canonicalName) {
                let substituteRequired = scaledRequired.map { $0 * swap.gramsFactor }
                let substitute = assess(ingredient: swap.substitute, requiredGrams: substituteRequired, preparation: line.preparation)
                if substitute.state == .satisfied {
                    // A stale rescue never reserves: the cook must confirm
                    // the substitute's evidence before it is used.
                    if !substitute.stale {
                        reserve(FLStockFold.groupKey(for: swap.substitute), usableIDs: substitute.usableLotIDs, satisfiedGrams: substituteRequired)
                    }
                    let covered: FLFeasibilityLineState = substitute.stale
                        ? .needsReconfirming
                        : .satisfied
                    return try buildLine(
                        line.lineID,
                        ingredient: line.ingredient,
                        state: covered,
                        availableGrams: substitute.availableGrams,
                        requiredGrams: substituteRequired,
                        reason: substitute.stale
                            ? "'\(line.ingredient.canonicalName)' is covered by '\(swap.substitute.canonicalName)' through an accepted swap, but the shelf evidence is stale — reconfirm"
                            : "'\(line.ingredient.canonicalName)' is covered by '\(swap.substitute.canonicalName)' through an accepted swap; you have \(gramsLabel(substitute.availableGrams ?? 0))",
                        viaSwap: !substitute.stale
                    )
                }
                // The substitute could not cover the line; the asked-for
                // identity's own evidence decides below.
            }

            // 4. A staple with no record at all is assumed (SPEC 3.2
            // "assumed staple") — an assumption, never evidence, so the
            // line cannot count as satisfied. A record that exists (even
            // an empty one) is not assumed away.
            guard hasRecord else {
                if staples.contains(line.ingredient.canonicalName.lowercased()) {
                    return try buildLine(
                        line.lineID,
                        ingredient: line.ingredient,
                        state: .assumedStaple,
                        availableGrams: nil,
                        requiredGrams: scaledRequired,
                        reason: "'\(line.ingredient.canonicalName)' is assumed from the staple shelf; confirm if your kitchen differs"
                    )
                }
                return try buildLine(
                    line.lineID,
                    ingredient: line.ingredient,
                    state: .missing,
                    availableGrams: nil,
                    requiredGrams: scaledRequired,
                    reason: "'\(line.ingredient.canonicalName)' is not on the shelf"
                )
            }

            // Stale evidence flips a confident line into a shelf check; the
            // numbers stay known, only freshness is in question.
            if (asked.state == .satisfied || asked.state == .short) && asked.stale {
                asked.state = .needsReconfirming
                asked.reason += ". The shelf evidence is stale — reconfirm"
            }

            switch asked.state {
            case .satisfied:
                reserve(key, usableIDs: asked.usableLotIDs, satisfiedGrams: scaledRequired)
            case .short:
                reserve(key, usableIDs: asked.usableLotIDs, satisfiedGrams: nil)
            default:
                break
            }
            return try buildLine(
                line.lineID,
                ingredient: line.ingredient,
                state: asked.state,
                availableGrams: asked.availableGrams,
                requiredGrams: scaledRequired,
                reason: asked.reason
            )
        }

        // Required lines first, in recipe order — allocation order matters.
        var requiredLines: [FLFeasibilityLine] = []
        for line in recipe.requiredIngredientLines {
            requiredLines.append(try evaluateLine(line))
        }
        // Garnish is evaluated against what remains and never reserves stock;
        // its states never affect the outcome (SPEC 3.2).
        var garnish: [FLFeasibilityLine] = []
        for line in recipe.ingredientLines where line.isOptionalGarnish {
            garnish.append(try evaluateLine(line))
        }

        return try FLFeasibilityReport(
            recipeKey: recipe.key,
            outcome: requiredLines.allSatisfy({ $0.state == .satisfied }) ? .complete : (
                requiredLines.contains(where: { $0.state == .blockedByRestriction }) ? .blocked : .partial
            ),
            lines: requiredLines,
            garnishLines: garnish,
            fitLine: Self.fitLine(requiredLines: requiredLines)
        )
    }

    // MARK: The fit line: SPEC 3.2's two honest shapes.
    //
    // "9 of 10 · 1 swap" only when every line is satisfied — the numerator
    // counts stock-satisfied lines and swaps are the suffix, so a swap
    // always shows in the attribution. Anything else falls to
    // "N recorded · check …", naming up to three problem lines in bill
    // order. Never a percentage, and never a claim of completeness unless
    // every line is satisfied.

    private static func fitLine(requiredLines: [FLFeasibilityLine]) -> String {
        guard !requiredLines.isEmpty else {
            return "Nothing to check — this revision has no ingredient lines."
        }
        if let blocked = requiredLines.first(where: { $0.state == .blockedByRestriction }) {
            return "Blocked — \(blocked.ingredient.canonicalName) is excluded by this household's hard restrictions."
        }
        let swapCount = requiredLines.filter(\.viaSwap).count
        if requiredLines.allSatisfy({ $0.state == .satisfied }) {
            let suffix = swapCount > 0
                ? " · \(swapCount) swap\(swapCount == 1 ? "" : "s")"
                : ""
            return "\(requiredLines.count - swapCount) of \(requiredLines.count)\(suffix)"
        }
        // "Recorded" means real evidence stands behind the line: a staple
        // assumption is not evidence, so assumed lines join the check list.
        let recorded = requiredLines.filter { $0.state == .satisfied }.count
        let problems = requiredLines
            .filter { $0.state != .satisfied }
            .prefix(3)
            .map { $0.ingredient.canonicalName }
        // The else-branch always has at least one problem line.
        let named: String
        switch problems.count {
        case 1: named = problems[0]
        case 2: named = "\(problems[0]) and \(problems[1])"
        default: named = "\(problems[0]), \(problems[1]) and \(problems[2])"
        }
        return "\(recorded) recorded · check \(named)"
    }

    /// Grams formatted without trailing noise: 250 g, not 250.0 g.
    private static func gramsLabel(_ grams: Double) -> String {
        grams == grams.rounded() && abs(grams) < 1_000_000
            ? String(Int(grams))
            : String(format: "%.1f", grams)
    }
}
