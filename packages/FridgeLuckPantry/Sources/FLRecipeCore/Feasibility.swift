import Foundation
import FLDomain
import FLInventoryCore

// MARK: - Feasibility evidence (SPEC 3.2)
// The five line states and the report the app and backend share. The outcome
// is derived from line states and nothing else: unknown evidence can never
// yield "complete", optional garnish is never required, and a restricted
// required ingredient blocks the recipe outright.

/// The state of one required ingredient line against the household's pantry
/// evidence. Raw values are part of the cross-language fixture contract.
///
/// The five SPEC 3.2 states are `satisfied`, `short`, `missing` (quantity
/// unknown for an unrecorded shelf), `assumedStaple`, and `needsReconfirming`
/// (stale evidence). `uncertainStock` and `blockedByRestriction` keep the
/// operational distinctions the fit line needs: unknown-but-present stock is
/// a different action from absent stock, and a restricted line is a hard
/// stop, not a shopping trip.
public enum FLFeasibilityLineState: String, Codable, Sendable, CaseIterable {
    /// Known stock covers the line. Only reachable when both the requirement
    /// and the covering stock are known amounts.
    case satisfied
    /// Known stock covers part of the line; the shortfall is named.
    case short
    /// Nothing usable for this identity on the shelf (absent, used up, or
    /// only in a preparation form this line cannot use).
    case missing
    /// The line cannot be decided from evidence: the required amount is
    /// unknown, or the shelf stock exists but is uncounted. Counts against
    /// completeness — unknown never becomes a number.
    case uncertainStock
    /// The ingredient is a kitchen staple with no pantry record at all; the
    /// app assumes it rather than sending the user shopping for salt.
    /// Assumption is not evidence: the line never counts as satisfied.
    case assumedStaple
    /// The stock evidence behind the line was last confirmed before the
    /// reconfirm window, so the amount may have drifted. The action is to
    /// look at the shelf, not to shop.
    case needsReconfirming
    /// The household's hard restrictions forbid this ingredient.
    case blockedByRestriction
}

/// Evidence for one ingredient line: its state, the numbers behind the state
/// (each present only when actually known), and a reason that never
/// overclaims.
public struct FLFeasibilityLine: Hashable, Sendable {
    public let lineID: String
    public let state: FLFeasibilityLineState
    public let ingredient: IngredientReference
    /// Known grams the line can draw from across its usable lots, when known.
    public let availableGrams: Double?
    /// Known grams the line requires, when the line carries that evidence.
    public let requiredGrams: Double?
    /// Human-facing why. States what IS known; never invents a number.
    public let reason: String
    /// True when the line is satisfied through an accepted swap (the pantry
    /// covered it with the substitute's lots, not the asked-for identity).
    /// Feeds the fit line's "· K swaps" attribution (SPEC 3.2).
    public let viaSwap: Bool

    public init(
        lineID: String,
        state: FLFeasibilityLineState,
        ingredient: IngredientReference,
        availableGrams: Double?,
        requiredGrams: Double?,
        reason: String,
        viaSwap: Bool = false
    ) throws {
        let trimmedLine = lineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            throw FLDomainError.validation(target: "FLFeasibilityLine.lineID", reason: "must not be empty")
        }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw FLDomainError.validation(target: "FLFeasibilityLine.reason", reason: "must not be empty")
        }
        if let availableGrams {
            guard availableGrams.isFinite, availableGrams >= 0 else {
                throw FLDomainError.validation(target: "FLFeasibilityLine.availableGrams", reason: "must be a finite non-negative amount when known (got \(availableGrams))")
            }
        }
        if let requiredGrams {
            guard requiredGrams.isFinite, requiredGrams >= 0 else {
                throw FLDomainError.validation(target: "FLFeasibilityLine.requiredGrams", reason: "must be a finite non-negative amount when known (got \(requiredGrams))")
            }
        }
        self.lineID = trimmedLine
        self.state = state
        self.ingredient = ingredient
        self.availableGrams = availableGrams
        self.requiredGrams = requiredGrams
        self.reason = trimmedReason
        self.viaSwap = viaSwap
    }
}

extension FLFeasibilityLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case lineID, state, ingredient, availableGrams, requiredGrams, reason, viaSwap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lineID: try container.decode(String.self, forKey: .lineID),
            state: try container.decode(FLFeasibilityLineState.self, forKey: .state),
            ingredient: try container.decode(IngredientReference.self, forKey: .ingredient),
            availableGrams: try container.decodeIfPresent(Double.self, forKey: .availableGrams),
            requiredGrams: try container.decodeIfPresent(Double.self, forKey: .requiredGrams),
            reason: try container.decode(String.self, forKey: .reason),
            viaSwap: try container.decodeIfPresent(Bool.self, forKey: .viaSwap) ?? false
        )
    }
}

/// The feasibility verdict for one recipe against one pantry snapshot.
public struct FLFeasibilityReport: Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// Every required line is satisfied on known evidence.
        case complete
        /// Cookable with shopping; the missing ingredients are named.
        case partial
        /// A required line is forbidden by the household's hard restrictions.
        case blocked
    }

    public let recipeKey: RecipeKey
    public let outcome: Outcome
    /// Every required line, in recipe order. Optional garnish lines follow,
    /// also evaluated, but never required for the outcome.
    public let lines: [FLFeasibilityLine]
    public let garnishLines: [FLFeasibilityLine]
    /// One line the app can show as-is. Never overclaims: a partial report
    /// never suggests the recipe is cookable as-is; an uncertain line says
    /// the stock is uncounted rather than sufficient or missing.
    public let fitLine: String

    /// Required lines whose evidence is not satisfied, deduplicated by
    /// ingredient identity (the same ingredient on two lines is one shopping
    /// entry), in first-appearance order.
    public var missingIngredients: [IngredientReference] {
        var seen: Set<String> = []
        var result: [IngredientReference] = []
        for line in lines where line.state != .satisfied {
            let key = FLStockFold.groupKey(for: line.ingredient)
            if seen.insert(key).inserted {
                result.append(line.ingredient)
            }
        }
        return result
    }

    public init(
        recipeKey: RecipeKey,
        outcome: Outcome,
        lines: [FLFeasibilityLine],
        garnishLines: [FLFeasibilityLine],
        fitLine: String
    ) throws {
        let trimmedFit = fitLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFit.isEmpty else {
            throw FLDomainError.validation(target: "FLFeasibilityReport.fitLine", reason: "must not be empty")
        }
        // Outcome derivation is enforced here so no caller can overclaim:
        // a restricted required line blocks; otherwise completeness requires
        // every required line satisfied on known evidence.
        let derived: Outcome
        if lines.contains(where: { $0.state == .blockedByRestriction }) {
            derived = .blocked
        } else if lines.allSatisfy({ $0.state == .satisfied }) {
            derived = .complete
        } else {
            derived = .partial
        }
        guard derived == outcome else {
            throw FLDomainError.validation(
                target: "FLFeasibilityReport.outcome",
                reason: "outcome '\(outcome.rawValue)' does not follow from the line states (expected '\(derived.rawValue)')"
            )
        }
        self.recipeKey = recipeKey
        self.outcome = derived
        self.lines = lines
        self.garnishLines = garnishLines
        self.fitLine = trimmedFit
    }
}

extension FLFeasibilityReport: Codable {
    private enum CodingKeys: String, CodingKey {
        case recipeKey, outcome, lines, garnishLines, fitLine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recipeKey: try container.decode(RecipeKey.self, forKey: .recipeKey),
            outcome: try container.decode(Outcome.self, forKey: .outcome),
            lines: try container.decode([FLFeasibilityLine].self, forKey: .lines),
            garnishLines: try container.decode([FLFeasibilityLine].self, forKey: .garnishLines),
            fitLine: try container.decode(String.self, forKey: .fitLine)
        )
    }
}
