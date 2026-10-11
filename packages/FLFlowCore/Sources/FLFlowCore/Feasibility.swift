import Foundation
import FLDomain

// MARK: - Feasibility
// SPEC 3.2: fit is computed over the complete ingredient bill for the chosen
// recipe revision, servings and accepted swaps; repeated lines are summed;
// optional garnish is separate; every required line lands in exactly one of
// the five states — sufficient, short (with the amount), quantity unknown,
// assumed staple, needs reconfirming. Unknown pantry evidence is surfaced as
// unknown, never guessed into a number.

/// The five line states of SPEC 3.2, with the amounts that make each state
/// checkable. A line has exactly one state; no boolean can contradict it.
public enum LineState: Hashable, Sendable {
    /// Stock covers the demand.
    case sufficient
    /// Stock falls short, with the requested and available amounts.
    case short(requestedGrams: Double, availableGrams: Double)
    /// No quantity evidence exists on one side. Never resolved by guessing.
    case quantityUnknown
    /// No evidence needed: a policy staple assumed present without stock.
    case assumedStaple
    /// Quantity evidence exists but is stale (or never confirmed) — reconfirm
    /// before trusting it.
    case needsReconfirming(lastConfirmedAt: Date?)
}

/// The evaluation of one summed required demand.
public struct LineFit: Hashable, Sendable {
    /// The summed demand's canonical ingredient name.
    public let canonicalName: String
    public let state: LineState
    /// The total requested grams when the recipe side carries evidence.
    public let requestedGrams: Double?

    public init(canonicalName: String, state: LineState, requestedGrams: Double?) {
        self.canonicalName = canonicalName
        self.state = state
        self.requestedGrams = requestedGrams
    }
}

/// Feasibility of one recipe revision against a ledger, in bill order.
public struct FeasibilityResult: Sendable {
    /// One entry per summed required demand, in first-appearance order.
    public let lineFits: [LineFit]
    /// Required lines that were skipped because the ingredient is an optional
    /// garnish are never here — garnish is separate (SPEC 3.2).

    public init(lineFits: [LineFit]) {
        self.lineFits = lineFits
    }

    public var isReady: Bool {
        lineFits.allSatisfy { fit in
            switch fit.state {
            case .sufficient, .assumedStaple: return true
            case .short, .quantityUnknown, .needsReconfirming: return false
            }
        }
    }

    /// Required line count in the summed bill.
    public var requiredCount: Int { lineFits.count }

    /// Count of lines whose state lets tonight proceed (sufficient or staple).
    public var sufficientCount: Int {
        lineFits.filter { fit in
            switch fit.state {
            case .sufficient, .assumedStaple: return true
            case .short, .quantityUnknown, .needsReconfirming: return false
            }
        }.count
    }

    /// Count of lines whose evidence shows the ingredient is present at all
    /// (sufficient, assumed staple, or short-but-on-the-shelf). The reason
    /// line may honestly call these "in stock"; shortfalls live in the
    /// missing list. Unknown and stale evidence are not presence.
    public var presentCount: Int {
        lineFits.filter { fit in
            switch fit.state {
            case .sufficient, .assumedStaple, .short: return true
            case .quantityUnknown, .needsReconfirming: return false
            }
        }.count
    }

    /// Canonical names of required lines that need attention, in bill order.
    public var checkNames: [String] {
        lineFits.filter { fit in
            switch fit.state {
            case .sufficient, .assumedStaple: return false
            case .short, .quantityUnknown, .needsReconfirming: return true
            }
        }.map(\.canonicalName)
    }
}

/// The pure feasibility engine. `evaluate` never throws on ordinary pantry
/// gaps — a shortage is a state, not an error — and never invents quantities.
public enum FeasibilityEngine {

    /// The summed required demands of one revision, scaled to the requested
    /// servings. Recipe quantities are written for the revision's serving
    /// basis; scale factors below 1 (smaller households) keep the demand as
    /// written — you do not buy a third of an egg — but the engine scales the
    /// arithmetic honestly and lets the caller decide rounding, because any
    /// rounding is a display decision.
    public static func summedDemands(for revision: RecipeRevision, servings: Int) throws -> [(canonicalName: String, grams: Double?)] {
        guard servings >= 1 else {
            throw FLFlowError.validation(target: "summedDemands.servings", reason: "must be >= 1 (got \(servings))")
        }
        // Scale factor from the revision's serving basis to the requested
        // servings; quantities scale linearly with evidence, never invented.
        let factor = Double(servings) / Double(revision.servingBasis.servings)

        var order: [String] = []
        var totals: [String: Double] = [:]
        var unknownNames: Set<String> = []

        for line in revision.requiredIngredientLines {
            let name = line.ingredient.canonicalName
            if !totals.keys.contains(name) && !unknownNames.contains(name) {
                order.append(name)
            }
            switch line.quantity.gramsIfKnown {
            case .some(let mass):
                if !unknownNames.contains(name) {
                    totals[name, default: 0] += mass.grams * factor
                }
            case .none:
                // Unknown demand evidence poisons the whole summed line: part
                // of it is unmeasurable, so the summed demand is unknown.
                totals.removeValue(forKey: name)
                unknownNames.insert(name)
            }
        }

        return order.map { name in
            (canonicalName: name, grams: unknownNames.contains(name) ? nil : totals[name])
        }
    }

    /// Evaluates one revision's required bill against a ledger **without**
    /// reserving stock — a look, not an allocation.
    public static func evaluate(
        revision: RecipeRevision,
        servings: Int,
        pantry: PantryView,
        ledger: StockLedger
    ) throws -> FeasibilityResult {
        var readLedger = ledger
        return try evaluateAndReserve(revision: revision, servings: servings, pantry: pantry, ledger: &readLedger)
    }

    /// Evaluates one revision's required bill and reserves what is sufficient
    /// from `ledger`, so the next dinner in a plan sees the remaining stock.
    /// Shortfalls, unknowns and stale evidence are never consumed.
    public static func evaluateAndReserve(
        revision: RecipeRevision,
        servings: Int,
        pantry: PantryView,
        ledger: inout StockLedger
    ) throws -> FeasibilityResult {
        let demands = try summedDemands(for: revision, servings: servings)
        var fits: [LineFit] = []

        for demand in demands {
            let name = demand.canonicalName

            // No pantry line at all: a policy staple is assumed present;
            // anything else is a shortage with available = 0.
            guard let pantryLine = pantry.line(for: name) else {
                if pantry.policy.stapleNames.contains(name) {
                    fits.append(LineFit(canonicalName: name, state: .assumedStaple, requestedGrams: demand.grams))
                } else {
                    fits.append(LineFit(
                        canonicalName: name,
                        state: .short(requestedGrams: demand.grams ?? 0, availableGrams: 0),
                        requestedGrams: demand.grams
                    ))
                }
                continue
            }

            // Unknown pantry evidence stays unknown (SPEC 3.2).
            if pantryLine.quantity.isUnknown {
                fits.append(LineFit(canonicalName: name, state: .quantityUnknown, requestedGrams: demand.grams))
                continue
            }

            // Stale or never-confirmed evidence needs reconfirming first.
            if pantry.isStale(pantryLine) {
                fits.append(LineFit(
                    canonicalName: name,
                    state: .needsReconfirming(lastConfirmedAt: pantryLine.lastConfirmedAt),
                    requestedGrams: demand.grams
                ))
                continue
            }

            // Known evidence on both sides: compare amounts against the
            // ledger — the reservation view over the pantry — so a plan's
            // second dinner sees what the first reserved, never the raw
            // shelf again.
            guard let requested = demand.grams else {
                // The recipe line itself has no measurable quantity.
                fits.append(LineFit(canonicalName: name, state: .quantityUnknown, requestedGrams: nil))
                continue
            }
            let availableGrams: Double?
            switch ledger.entry(for: name) {
            case .some(.known(let remaining)):
                availableGrams = remaining.grams
            case .some(.unknown):
                availableGrams = nil
            case .none:
                // The ledger was not seeded from this pantry view: record
                // the pantry baseline so reservations carry from here on.
                if let pantryGrams = pantryLine.quantity.gramsIfKnown {
                    ledger.record(canonicalName: name, grams: try GramMass(grams: pantryGrams.grams))
                    availableGrams = pantryGrams.grams
                } else {
                    availableGrams = nil
                }
            }
            guard let availableAmount = availableGrams else {
                fits.append(LineFit(canonicalName: name, state: .quantityUnknown, requestedGrams: requested))
                continue
            }
            if availableAmount >= requested {
                try ledger.consume(canonicalName: name, grams: GramMass(grams: requested))
                fits.append(LineFit(canonicalName: name, state: .sufficient, requestedGrams: requested))
            } else {
                fits.append(LineFit(
                    canonicalName: name,
                    state: .short(requestedGrams: requested, availableGrams: availableAmount),
                    requestedGrams: requested
                ))
            }
        }

        return FeasibilityResult(lineFits: fits)
    }
}
