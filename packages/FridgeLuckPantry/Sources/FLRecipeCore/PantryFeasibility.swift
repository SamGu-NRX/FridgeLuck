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
    /// One working lot: identity of the source lot, its form, and what
    /// remains (nil = uncounted).
    private struct PoolLot {
        let lotID: String
        let preparation: String?
        var remainingGrams: Double?
    }

    public static func evaluate(
        recipe: RecipeRevision,
        stock: [FLItemStock],
        restriction: Restriction,
        transforms: FLPreparationTransforms = .standard
    ) throws -> FLFeasibilityReport {
        // Working pool: group key → lots (oldest first), decremented as
        // satisfied/short lines reserve or consume.
        var pool: [String: [PoolLot]] = [:]
        for item in stock {
            pool[FLStockFold.groupKey(for: item.ingredient)] = item.lots.map { lot in
                PoolLot(
                    lotID: lot.lotID,
                    preparation: lot.preparation,
                    remainingGrams: lot.remaining.gramsIfKnown?.grams
                )
            }
        }

        func evaluateLine(_ line: IngredientLine) throws -> FLFeasibilityLine {
            let key = FLStockFold.groupKey(for: line.ingredient)

            // 1. Hard restrictions are absolute (SPEC 3.3): the union of the
            // household's restrictions filters candidates; stock never
            // matters for a forbidden ingredient.
            guard restriction.permits(canonicalName: line.ingredient.canonicalName) else {
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .blockedByRestriction,
                    ingredient: line.ingredient,
                    availableGrams: nil,
                    requiredGrams: line.quantity.gramsIfKnown?.grams,
                    reason: "'\(line.ingredient.canonicalName)' is excluded by this household's hard restrictions"
                )
            }

            // 2. Identity on the shelf at all?
            guard let lots = pool[key], !lots.isEmpty else {
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .missing,
                    ingredient: line.ingredient,
                    availableGrams: nil,
                    requiredGrams: line.quantity.gramsIfKnown?.grams,
                    reason: "'\(line.ingredient.canonicalName)' is not on the shelf"
                )
            }

            // 3. Any lot in a form this line can use?
            let usable = lots.filter { transforms.lotUsable(forLine: line.preparation, lotPreparation: $0.preparation) }
            let usableIDs = Set(usable.map(\.lotID))
            guard !usable.isEmpty else {
                let forms = Set(lots.compactMap(\.preparation)).sorted().joined(separator: ", ")
                let needForm = line.preparation ?? "raw"
                let reason = forms.isEmpty
                    ? "'\(line.ingredient.canonicalName)' is only on the shelf in prepared forms; this line needs it \(needForm)"
                    : "'\(line.ingredient.canonicalName)' is on the shelf only as \(forms); this line needs it \(needForm)"
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .missing,
                    ingredient: line.ingredient,
                    availableGrams: nil,
                    requiredGrams: line.quantity.gramsIfKnown?.grams,
                    reason: reason
                )
            }

            // 4. Is the required amount known? Unknown never becomes a number.
            guard let required = line.quantity.gramsIfKnown else {
                let counted = usable.compactMap(\.remainingGrams)
                let allCounted = counted.count == usable.count
                let available = allCounted ? counted.reduce(0, +) : nil
                let shelf = available.map { "the shelf shows \(gramsLabel($0))" } ?? "the shelf amount is uncounted"
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .uncertainStock,
                    ingredient: line.ingredient,
                    availableGrams: available,
                    requiredGrams: nil,
                    reason: "the recipe amount for '\(line.ingredient.canonicalName)' is unmeasured; \(shelf)"
                )
            }

            // 5. Is the usable stock fully counted?
            let knownGrams = usable.compactMap(\.remainingGrams)
            guard knownGrams.count == usable.count else {
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .uncertainStock,
                    ingredient: line.ingredient,
                    availableGrams: nil,
                    requiredGrams: required.grams,
                    reason: "the shelf stock of '\(line.ingredient.canonicalName)' is uncounted, so \(gramsLabel(required.grams)) cannot be confirmed"
                )
            }

            // 6. Do the known grams cover the requirement?
            let total = knownGrams.reduce(0, +)
            if total >= required.grams {
                // Reserve FIFO, oldest first, so later lines of the same
                // ingredient see the true remainder.
                var toTake = required.grams
                for index in pool[key]!.indices where usableIDs.contains(pool[key]![index].lotID) {
                    guard toTake > 0 else { break }
                    if let remaining = pool[key]![index].remainingGrams, remaining > 0 {
                        let taken = min(remaining, toTake)
                        pool[key]![index].remainingGrams = remaining - taken
                        toTake -= taken
                    }
                }
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .satisfied,
                    ingredient: line.ingredient,
                    availableGrams: total,
                    requiredGrams: required.grams,
                    reason: "you have \(gramsLabel(total)), the recipe needs \(gramsLabel(required.grams))"
                )
            } else if total > 0 {
                // Short: the cook uses what is there and shops the shortfall;
                // the shown amount is consumed from the pool so later lines
                // of the same ingredient are judged on the true remainder.
                for index in pool[key]!.indices where usableIDs.contains(pool[key]![index].lotID) {
                    pool[key]![index].remainingGrams = 0
                }
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .short,
                    ingredient: line.ingredient,
                    availableGrams: total,
                    requiredGrams: required.grams,
                    reason: "the recipe needs \(gramsLabel(required.grams)), you have \(gramsLabel(total))"
                )
            } else {
                return try FLFeasibilityLine(
                    lineID: line.lineID,
                    state: .missing,
                    ingredient: line.ingredient,
                    availableGrams: 0,
                    requiredGrams: required.grams,
                    reason: "the recipe needs \(gramsLabel(required.grams)), but no '\(line.ingredient.canonicalName)' is left"
                )
            }
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
            fitLine: Self.fitLine(recipe: recipe, requiredLines: requiredLines)
        )
    }

    // MARK: The fit line: deterministic, and never overclaiming.

    private static func fitLine(recipe: RecipeRevision, requiredLines: [FLFeasibilityLine]) -> String {
        if let blocked = requiredLines.first(where: { $0.state == .blockedByRestriction }) {
            return "Blocked — \(blocked.ingredient.canonicalName) is excluded by this household's hard restrictions."
        }
        guard requiredLines.allSatisfy({ $0.state == .satisfied }) else {
            let problems = requiredLines.filter { $0.state != .satisfied }
            let named = problems.prefix(3).map { line -> String in
                switch line.state {
                case .short:
                    if let have = line.availableGrams, let need = line.requiredGrams {
                        return "\(line.ingredient.canonicalName) (short by \(gramsLabel(need - have)) g)"
                    }
                    return line.ingredient.canonicalName
                case .missing:
                    return line.ingredient.canonicalName
                case .uncertainStock:
                    return "\(line.ingredient.canonicalName) (check the shelf — the amount is uncounted)"
                default:
                    return line.ingredient.canonicalName
                }
            }
            let more = problems.count > 3 ? " and \((problems.count - 3)) more" : ""
            return "Not yet — shop \(named.joined(separator: ", "))\(more) first."
        }
        return "You can cook \(recipe.title) with what's on the shelf."
    }

    /// Grams formatted without trailing noise: 250 g, not 250.0 g.
    private static func gramsLabel(_ grams: Double) -> String {
        grams == grams.rounded() && abs(grams) < 1_000_000
            ? String(Int(grams))
            : String(format: "%.1f", grams)
    }
}
