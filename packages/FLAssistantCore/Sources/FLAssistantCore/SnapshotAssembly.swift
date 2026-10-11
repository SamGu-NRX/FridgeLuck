import Foundation
import FLDomain

// MARK: - Snapshot assembly inputs
// The host's stores own pantry data; this layer reads it through
// `AssistantStateSource`. The source hands over plain, host-constructible
// values (`AssistantPantryLine`), and the builder turns them into FLDomain's
// snapshot lines.

/// One pantry line as the host reports it, before it becomes part of a
/// snapshot. Quantity evidence passes through untouched — `.unknown` stays
/// unknown all the way to the model.
public struct AssistantPantryLine: Hashable, Sendable {
    public let canonicalName: String
    public let quantity: QuantityEvidence
    public let lastConfirmedAt: Date?

    public init(canonicalName: String, quantity: QuantityEvidence, lastConfirmedAt: Date?) {
        self.canonicalName = canonicalName
        self.quantity = quantity
        self.lastConfirmedAt = lastConfirmedAt
    }
}

extension AssistantContextSnapshot {
    /// Build one `PantrySummaryLine` through FLDomain's public validated
    /// initializer (shipped in the foundation review fixes, PR #90): the
    /// canonical name is never empty, quantity evidence passes through
    /// untouched, unknown stays unknown.
    public static func makePantryLine(
        canonicalName: String,
        quantity: QuantityEvidence,
        lastConfirmedAt: Date?
    ) throws -> PantrySummaryLine {
        try PantrySummaryLine(canonicalName: canonicalName, quantity: quantity, lastConfirmedAt: lastConfirmedAt)
    }
}
