import Foundation
import FLDomain

// MARK: - Pantry truth port
// SPEC 3.2: the fit line is the app's central promise, so it must be true.
// FLFlowCore does not own inventory (the inventory core owns it); this file
// defines the explicit input port the inventory core feeds, plus the stock
// ledger that allocates quantities across lines, swaps and several dinners in
// a plan without counting the same stock twice.
//
// The port deliberately carries only what the flows need: canonical name,
// quantity evidence, last confirmation and source. Unknown quantity is a
// first-class value that reaches the flows as unknown and is never guessed.

/// One pantry line as the flows see it. The inventory core (a parallel part)
/// constructs these; the flows never invent one.
public struct FlowPantryLine: Hashable, Sendable {
    /// Canonical ingredient name, e.g. "whole milk". Never empty. The resolver
    /// owns canonicalization; the flows match lines by this name exactly.
    public let canonicalName: String
    /// Quantity evidence, unknown included. Recognition confidence is not
    /// quantity confidence (SPEC 3.2): a confident detection of an unknown
    /// amount is still unknown.
    public let quantity: QuantityEvidence
    /// The last confirmation of this line, when any. `nil` means the line was
    /// never confirmed — weak evidence the flows surface, not fill in.
    public let lastConfirmedAt: Date?
    /// Where the line came from (e.g. "shelf scan", "receipt"). Never empty.
    public let source: String

    public init(canonicalName: String, quantity: QuantityEvidence, lastConfirmedAt: Date?, source: String) throws {
        let trimmed = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLFlowError.validation(target: "FlowPantryLine.canonicalName", reason: "must not be empty")
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw FLFlowError.validation(target: "FlowPantryLine.source", reason: "must not be empty")
        }
        self.canonicalName = trimmed
        self.quantity = quantity
        self.lastConfirmedAt = lastConfirmedAt
        self.source = trimmedSource
    }
}

/// The pantry policy the flows evaluate against: which names are assumed
/// staples without evidence, and how old a confirmation may be before the
/// evidence counts as stale (needs reconfirming).
public struct PantryPolicy: Hashable, Sendable {
    /// Canonical names assumed present without evidence (salt, oil, ...).
    /// Assumed staples are surfaced as such, never claimed as stock.
    public var stapleNames: Set<String>
    /// A confirmation older than this many seconds is stale evidence.
    public var stalenessHorizonSeconds: Double

    /// Policy defaults. The literals are valid by construction — `try!` can
    /// only trap if a future edit breaks an invariant, which must fail loudly.
    public static let `default` = try! PantryPolicy(
        stapleNames: ["salt", "black pepper", "olive oil", "vegetable oil", "water", "all-purpose flour", "sugar"],
        stalenessHorizonSeconds: 14 * 24 * 60 * 60  // two weeks
    )

    public init(stapleNames: Set<String>, stalenessHorizonSeconds: Double) throws {
        for name in stapleNames {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FLFlowError.validation(target: "PantryPolicy.stapleNames", reason: "staple names must not be empty")
            }
        }
        guard stalenessHorizonSeconds.isFinite, stalenessHorizonSeconds > 0 else {
            throw FLFlowError.validation(target: "PantryPolicy.stalenessHorizonSeconds", reason: "must be finite and > 0 (got \(stalenessHorizonSeconds))")
        }
        self.stapleNames = stapleNames
        self.stalenessHorizonSeconds = stalenessHorizonSeconds
    }
}

/// The pantry as one evaluation input: the lines the inventory core reported,
/// the policy, and the reference time. A pantry view is a snapshot — the flows
/// never mutate it.
public struct PantryView: Sendable {
    public let lines: [FlowPantryLine]
    public let policy: PantryPolicy
    public let now: Date

    public init(lines: [FlowPantryLine], policy: PantryPolicy = .default, now: Date) {
        self.lines = lines
        self.policy = policy
        self.now = now
    }

    /// Lines indexed by canonical name. The first line for a name wins; the
    /// inventory core owns reconciliation of duplicates ("a scan of one shelf
    /// refreshes only what it saw").
    public func line(for canonicalName: String) -> FlowPantryLine? {
        lines.first(where: { $0.canonicalName == canonicalName })
    }

    /// Is the evidence for this line stale (or never confirmed)?
    public func isStale(_ line: FlowPantryLine) -> Bool {
        guard let confirmedAt = line.lastConfirmedAt else { return true }
        return now.timeIntervalSince(confirmedAt) > policy.stalenessHorizonSeconds
    }
}

// MARK: - Stock ledger

/// One ingredient's allocatable stock. Unknown stock is tracked as unknown: it
/// never supports "sufficient" and is never decremented, because consuming a
/// known demand from unknown stock would invent how much is left.
public enum StockEntry: Hashable, Sendable {
    case known(GramMass)
    case unknown
}

/// A reservation ledger across a plan: allocating one dinner's demands
/// consumes stock, so the next dinner in the plan is evaluated against what
/// actually remains (SPEC 4 Plan job: "reserving quantities across the plan").
public struct StockLedger: Sendable {
    private var stock: [String: StockEntry]

    /// Builds a ledger from a pantry view. Unknown-quantity lines enter the
    /// ledger as unknown.
    public init(pantry: PantryView) {
        var stock: [String: StockEntry] = [:]
        for line in pantry.lines {
            guard stock[line.canonicalName] == nil else { continue }
            if let grams = line.quantity.gramsIfKnown {
                stock[line.canonicalName] = .known(grams)
            } else if !line.quantity.isUnknown {
                // A measure that could not resolve to grams is still evidence
                // of presence without an amount: unknown, not zero.
                stock[line.canonicalName] = .unknown
            } else {
                stock[line.canonicalName] = .unknown
            }
        }
        self.stock = stock
    }

    /// Records a known baseline for a name the ledger has not seen. Callers
    /// normally seed the ledger from the same pantry view they evaluate;
    /// this keeps reservations honest when they do not. Never overwrites.
    public mutating func record(canonicalName: String, grams: GramMass) {
        guard stock[canonicalName] == nil else { return }
        stock[canonicalName] = .known(grams)
    }

    public func entry(for canonicalName: String) -> StockEntry? {
        stock[canonicalName]
    }

    /// Consumes `grams` of stock when it is known and sufficient; returns the
    /// remaining grams. When stock is unknown or less than the demand, nothing
    /// is consumed — a failed allocation must not corrupt the ledger.
    @discardableResult
    public mutating func consume(canonicalName: String, grams: GramMass) throws -> StockEntry? {
        guard let entry = stock[canonicalName] else { return nil }
        switch entry {
        case .unknown:
            return .unknown
        case let .known(available):
            guard available.grams >= grams.grams else { return .known(available) }
            let remaining = try GramMass(grams: available.grams - grams.grams)
            stock[canonicalName] = .known(remaining)
            return .known(remaining)
        }
    }
}
