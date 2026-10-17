import Foundation

/// Errors thrown when a stock event cannot be applied to the pantry ledger.
///
/// Every rejection rule of the pantry-truth contract (SPEC 3.2) throws this
/// type, so a caller can distinguish "event refused at the boundary" from any
/// other failure. A refused event never mutates the ledger: the append-only
/// event log and the folded stock stay exactly as they were.
public enum FLInventoryError: Error, Equatable, Sendable {
    /// A known-quantity reduction would exceed the recorded stock. The ledger
    /// never lets stock go negative: record a correction (or a purchase) for
    /// the missing stock first, then retry the reduction.
    case insufficientStock(
        ingredient: String, availableGrams: Double, requestedGrams: Double, eventID: String
    )
    /// A correction references an event that does not exist in this
    /// household's ledger (or not yet — corrections arrive in sequence).
    case unknownEventReference(eventID: String, referencedEventID: String)
    /// A correction names a different ingredient than the event it revises.
    /// Corrections never move stock between items.
    case correctionIngredientMismatch(eventID: String, correctedIngredient: String, recordedIngredient: String)
    /// An event ID was reused with a different command. Event identity is
    /// immutable; a retry reuses BOTH the event ID and the command ID.
    case duplicateEventID(eventID: String)
    /// A structural rule of the ledger is violated (a correction targeting
    /// another correction, a purchase carrying a lot target, ...).
    case invalidEvent(eventID: String, reason: String)
    /// The event's household is not the ledger's household — cross-household
    /// writes are refused rather than silently mixed (SPEC 3.2: one person's
    /// pantry on one phone; a synced household pantry is a later decision).
    case householdMismatch(eventID: String)
}

extension FLInventoryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .insufficientStock(ingredient, available, requested, eventID):
            return "FLInventory refused \(eventID): \(ingredient) stock \(available) g is below the requested \(requested) g; record a correction first — stock never goes negative"
        case let .unknownEventReference(eventID, referenced):
            return "FLInventory refused \(eventID): it references unknown event \(referenced)"
        case let .correctionIngredientMismatch(eventID, corrected, recorded):
            return "FLInventory refused \(eventID): correction names '\(corrected)' but the revised event recorded '\(recorded)'"
        case let .duplicateEventID(eventID):
            return "FLInventory refused \(eventID): event ID already applied under a different command"
        case let .invalidEvent(eventID, reason):
            return "FLInventory refused \(eventID): \(reason)"
        case let .householdMismatch(eventID):
            return "FLInventory refused \(eventID): event belongs to another household"
        }
    }
}
