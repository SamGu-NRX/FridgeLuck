import Foundation
import FLDomain

// MARK: - The pantry lot evidence view
// What feasibility (FLRecipeCore) consumes: current stock as evidence, never
// as invented numbers. A lot with `remaining == .unknown` is honestly
// uncounted stock — it can never prove a line sufficient. The backend reads
// exactly these bounded snapshots (SPEC §4); the shape is fixture-frozen.

/// Current stock of one lot: one purchase, one observation, or one leftover.
public struct FLPantryLot: Hashable, Sendable {
    /// Lot identity: the event that created it. Stable across folds.
    public let lotID: String
    public let ingredient: IngredientReference
    /// The preparation form this lot is already in ("cooked", "finely chopped").
    /// Raw stock has none and can be prepared freely.
    public let preparation: String?
    /// What remains. Unknown stays unknown — never a number.
    public let remaining: QuantityEvidence
    /// When this lot entered the ledger.
    public let createdAt: Date
    /// The last confirmation of this lot's existence and amount, with its
    /// source (a receipt, a scan, a manual entry). Consuming from a lot does
    /// not confirm what remains.
    public let lastConfirmedAt: Date?
    public let lastConfirmedSource: FLStockEventSource?

    public init(
        lotID: String,
        ingredient: IngredientReference,
        preparation: String? = nil,
        remaining: QuantityEvidence,
        createdAt: Date,
        lastConfirmedAt: Date?,
        lastConfirmedSource: FLStockEventSource?
    ) throws {
        let trimmed = lotID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "FLPantryLot.lotID", reason: "must not be empty")
        }
        self.lotID = trimmed
        self.ingredient = ingredient
        self.preparation = preparation
        self.remaining = remaining
        self.createdAt = createdAt
        self.lastConfirmedAt = lastConfirmedAt
        self.lastConfirmedSource = lastConfirmedSource
    }
}

extension FLPantryLot: Codable {
    private enum CodingKeys: String, CodingKey {
        case lotID, ingredient, preparation, remaining, createdAt, lastConfirmedAt, lastConfirmedSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lotID: try container.decode(String.self, forKey: .lotID),
            ingredient: try container.decode(IngredientReference.self, forKey: .ingredient),
            preparation: try container.decodeIfPresent(String.self, forKey: .preparation),
            remaining: try container.decode(QuantityEvidence.self, forKey: .remaining),
            createdAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .createdAt),
                target: "FLPantryLot.createdAt"
            ),
            lastConfirmedAt: try container.decodeIfPresent(String.self, forKey: .lastConfirmedAt).map {
                try FLTimestamp.decode($0, target: "FLPantryLot.lastConfirmedAt")
            },
            lastConfirmedSource: try container.decodeIfPresent(FLStockEventSource.self, forKey: .lastConfirmedSource)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lotID, forKey: .lotID)
        try container.encode(ingredient, forKey: .ingredient)
        try container.encodeIfPresent(preparation, forKey: .preparation)
        try container.encode(remaining, forKey: .remaining)
        try container.encode(FLTimestamp.encode(createdAt), forKey: .createdAt)
        try container.encodeIfPresent(lastConfirmedAt.map(FLTimestamp.encode), forKey: .lastConfirmedAt)
        try container.encodeIfPresent(lastConfirmedSource, forKey: .lastConfirmedSource)
    }
}

// MARK: - The fold
// Events → current stock. Pure, deterministic, and the ONLY place stock
// arithmetic lives: the GRDB ledger and the property tests both call this,
// so there is exactly one implementation of every invariant (SPEC 3.2):
// - corrections supersede rather than erase (last correction of a root wins);
// - scans observe, purchases add (an observation never stacks onto stock);
// - stock never goes negative: a known reduction beyond known stock is an
//   error; drawing from an uncounted lot leaves the lot uncounted;
// - unknown evidence stays unknown: an unmeasured removal leaves the amount
//   unknown, never zero and never a guess.

/// Current stock of one pantry item (one ingredient identity in one household).
public struct FLItemStock: Equatable, Sendable {
    /// The identity group key (see `FLStockFold.groupKey`).
    public let groupKey: String
    /// The most recently recorded reference for display.
    public let ingredient: IngredientReference
    /// Lots, oldest first. FIFO draw-down order.
    public let lots: [FLPantryLot]
    /// The item's last confirmation across all lots, and its source.
    public let lastConfirmedAt: Date?
    public let lastConfirmedSource: FLStockEventSource?

    /// Total remaining grams when every lot's remaining is known; `nil` when
    /// any lot is uncounted (or the item has no lots — an empty pantry item
    /// has no known amount, not zero).
    public var totalKnownRemainingGrams: Double? {
        guard !lots.isEmpty else { return nil }
        var total: Double = 0
        for lot in lots {
            guard let grams = lot.remaining.gramsIfKnown else { return nil }
            total += grams.grams
        }
        return total
    }
}

public enum FLStockFold {
    /// The identity group of a pantry item. The strongest available key wins:
    /// USDA FDC identity, then the local ingredient row ID, then the canonical
    /// name (case-insensitive). A purchase recorded with an FDC ID and a scan
    /// of the same shelf recorded by name are deliberately TWO groups — a
    /// conservative split undercounts (the fit line says "short" and the user
    /// corrects it), where a merge could overcount stock. The resolver
    /// pipeline (E14) upgrades identity; the ledger never guesses it.
    public static func groupKey(for ingredient: IngredientReference) -> String {
        if let fdc = ingredient.fdc {
            return "fdc:\(fdc.fdcID)"
        }
        if let local = ingredient.localIngredientID {
            return "local:\(local)"
        }
        return "name:\(ingredient.canonicalName.lowercased())"
    }

    /// Fold a household's events (in ingestion order) into current stock.
    /// Throws when the history itself is impossible: duplicate event IDs,
    /// corrections referencing unknown events or other corrections, a
    /// correction that moves the ingredient, or any intermediate state where
    /// a known reduction exceeds known stock (the ledger never rewrites
    /// history into a negative one).
    public static func fold(events: [FLStockEvent]) throws -> [FLItemStock] {
        var byID: [String: FLStockEvent] = [:]
        for event in events {
            guard byID[event.id.rawValue] == nil else {
                throw FLInventoryError.duplicateEventID(eventID: event.id.rawValue)
            }
            byID[event.id.rawValue] = event
        }

        // Resolve corrections: the last active correction of a root decides —
        // `.corrects` replaces the root's quantity, `.retracts` removes the
        // root. Corrections target roots only (never other corrections).
        var correctionPayload: [String: QuantityEvidence] = [:]
        var retractedRoots: Set<String> = []
        for event in events where event.kind == .correction {
            let correction = try unwrapCorrection(event)
            let priorID = correction.priorEventID.rawValue
            guard let prior = byID[priorID] else {
                throw FLInventoryError.unknownEventReference(
                    eventID: event.id.rawValue, referencedEventID: priorID
                )
            }
            guard prior.kind != .correction else {
                throw FLInventoryError.invalidEvent(
                    eventID: event.id.rawValue,
                    reason: "corrections target the event they revise, not another correction"
                )
            }
            guard FLStockFold.groupKey(for: prior.ingredient) == FLStockFold.groupKey(for: event.ingredient) else {
                throw FLInventoryError.correctionIngredientMismatch(
                    eventID: event.id.rawValue,
                    correctedIngredient: event.ingredient.canonicalName,
                    recordedIngredient: prior.ingredient.canonicalName
                )
            }
            switch correction.mode {
            case .corrects:
                correctionPayload[priorID] = event.quantity
                retractedRoots.remove(priorID)
            case .retracts:
                correctionPayload[priorID] = nil
                retractedRoots.insert(priorID)
            }
        }

        // Fold the effective stream, grouped by identity.
        var lots: [String: [MutableLot]] = [:]
        var display: [String: IngredientReference] = [:]
        var confirmations: [String: (Date, FLStockEventSource)] = [:]

        for event in events {
            // Corrections do not act on stock themselves.
            if event.kind == .correction { continue }
            let key = FLStockFold.groupKey(for: event.ingredient)
            display[key] = event.ingredient

            // A retracted event never happened; a corrected event carries the
            // correcting quantity instead of its own.
            if retractedRoots.contains(event.id.rawValue) { continue }
            let quantity = correctionPayload[event.id.rawValue] ?? event.quantity

            switch event.kind {
            case .purchase:
                let lot = MutableLot(
                    id: event.id.rawValue,
                    createdAt: event.timestamp,
                    preparation: event.preparation,
                    remainingGrams: quantity.gramsIfKnown?.grams,
                    lastConfirmedAt: event.timestamp,
                    lastConfirmedSource: event.source
                )
                lots[key, default: []].append(lot)
                confirmations[key] = (event.timestamp, event.source)
            case .consumption, .spoilage:
                try FLStockFold.reduce(
                    &lots[key, default: []],
                    by: quantity,
                    targetedLot: event.lotID,
                    eventID: event.id.rawValue,
                    ingredient: event.ingredient
                )
            case .observation:
                if let observed = quantity.gramsIfKnown {
                    // Reconcile: the scan saw the shelf, so the item's stock
                    // is exactly what was seen — one lot, refreshed evidence.
                    lots[key] = [MutableLot(
                        id: event.id.rawValue,
                        createdAt: event.timestamp,
                        preparation: event.preparation,
                        remainingGrams: observed.grams,
                        lastConfirmedAt: event.timestamp,
                        lastConfirmedSource: event.source
                    )]
                } else if (lots[key]?.isEmpty ?? true) {
                    // Presence without an amount: a lot that can never claim
                    // sufficiency until something counts it.
                    lots[key] = [MutableLot(
                        id: event.id.rawValue,
                        createdAt: event.timestamp,
                        preparation: event.preparation,
                        remainingGrams: nil,
                        lastConfirmedAt: event.timestamp,
                        lastConfirmedSource: event.source
                    )]
                } else {
                    // The scan confirms presence only; amounts stay as they
                    // were, and the confirmation timestamp refreshes.
                    for index in lots[key]!.indices {
                        lots[key]![index].lastConfirmedAt = event.timestamp
                        lots[key]![index].lastConfirmedSource = event.source
                    }
                }
                confirmations[key] = (event.timestamp, event.source)
            case .correction:
                break // corrections act through their root, not on stock
            }
        }

        var result: [FLItemStock] = []
        for key in lots.keys.sorted() {
            guard let mutableLots = lots[key] else { continue }
            guard let ingredient = display[key] else { continue }
            let pantryLots = try mutableLots.map { try $0.asPantryLot(ingredient: ingredient) }
            let confirmation = confirmations[key]
            result.append(FLItemStock(
                groupKey: key,
                ingredient: ingredient,
                lots: pantryLots,
                lastConfirmedAt: confirmation?.0,
                lastConfirmedSource: confirmation?.1
            ))
        }
        return result
    }

    // MARK: Implementation

    private struct MutableLot {
        var id: String
        var createdAt: Date
        var preparation: String?
        /// `nil` when the remaining amount is unknown.
        var remainingGrams: Double?
        var lastConfirmedAt: Date?
        var lastConfirmedSource: FLStockEventSource?

        func asPantryLot(ingredient: IngredientReference) throws -> FLPantryLot {
            let remaining: QuantityEvidence
            if let remainingGrams {
                remaining = .sourceGrams(try GramMass(grams: remainingGrams))
            } else {
                remaining = .unknown
            }
            return try FLPantryLot(
                lotID: id,
                ingredient: ingredient,
                preparation: preparation,
                remaining: remaining,
                createdAt: createdAt,
                lastConfirmedAt: lastConfirmedAt,
                lastConfirmedSource: lastConfirmedSource
            )
        }
    }

    private static func unwrapCorrection(_ event: FLStockEvent) throws -> FLStockCorrection {
        guard let correction = event.supersedes else {
            throw FLInventoryError.invalidEvent(
                eventID: event.id.rawValue,
                reason: "a correction must name the event it revises"
            )
        }
        return correction
    }

    /// Draw a reduction down through an item's lots, oldest first. Known lots
    /// are validated (never negative); an uncounted lot absorbs the rest
    /// honestly (it stays uncounted — the amount taken from it is unknown).
    private static func reduce(
        _ itemLots: inout [MutableLot],
        by quantity: QuantityEvidence,
        targetedLot: String?,
        eventID: String,
        ingredient: IngredientReference
    ) throws {
        guard let requested = quantity.gramsIfKnown else {
            // An unmeasured removal leaves every lot's amount unknown — the
            // honest answer to "how much is left?" is then "unknown", never
            // zero and never a guess (SPEC 3.2: recognition confidence is not
            // quantity confidence).
            for index in itemLots.indices {
                itemLots[index].remainingGrams = nil
            }
            if itemLots.isEmpty {
                throw FLInventoryError.insufficientStock(
                    ingredient: ingredient.canonicalName,
                    availableGrams: 0,
                    requestedGrams: 0,
                    eventID: eventID
                )
            }
            return
        }

        if let targetedLot {
            guard let index = itemLots.firstIndex(where: { $0.id == targetedLot }) else {
                throw FLInventoryError.invalidEvent(
                    eventID: eventID,
                    reason: "targets lot \(targetedLot), which this item does not have"
                )
            }
            guard let available = itemLots[index].remainingGrams else {
                return // drew from an uncounted lot; it stays uncounted
            }
            guard available >= requested.grams else {
                throw FLInventoryError.insufficientStock(
                    ingredient: ingredient.canonicalName,
                    availableGrams: available,
                    requestedGrams: requested.grams,
                    eventID: eventID
                )
            }
            itemLots[index].remainingGrams = available - requested
            return
        }

        // FIFO across known lots, oldest first.
        var remainingToTake = requested.grams
        for index in itemLots.indices {
            guard remainingToTake > 0 else { break }
            guard let available = itemLots[index].remainingGrams, available > 0 else { continue }
            let taken = min(available, remainingToTake)
            itemLots[index].remainingGrams = available - taken
            remainingToTake -= taken
        }
        // Any remainder draws from uncounted lots if present (they stay
        // uncounted); with none, the reduction exceeds recorded stock.
        if remainingToTake > 0 {
            let hasUncounted = itemLots.contains { $0.remainingGrams == nil }
            guard hasUncounted else {
                let knownTotal = itemLots.compactMap(\.remainingGrams).reduce(0, +)
                throw FLInventoryError.insufficientStock(
                    ingredient: ingredient.canonicalName,
                    availableGrams: knownTotal,
                    requestedGrams: requested.grams,
                    eventID: eventID
                )
            }
        }
    }
}
