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
    /// Build one `PantrySummaryLine`.
    ///
    /// FLDomain gap (recorded for Part 1's review, branch
    /// overhaul/core-foundation): `PantrySummaryLine` has no public
    /// memberwise initializer — it is only constructible inside FLDomain,
    /// whose tests use `@testable` access. Until Part 1 ships a public init,
    /// assembly goes through the canonical decoder, the same path every
    /// cross-language producer of a snapshot must satisfy anyway. The value
    /// produced is identical to what a memberwise init would return: nothing
    /// is reinterpreted or revalidated beyond FLDomain's own decoding.
    public static func makePantryLine(
        canonicalName: String,
        quantity: QuantityEvidence,
        lastConfirmedAt: Date?
    ) throws -> PantrySummaryLine {
        struct Shell: Codable {
            let canonicalName: String
            let quantity: QuantityEvidence
            // Synthesized Date coding on this type is the reference-epoch
            // Double (see the frozen FLDomain assistant fixtures), so the
            // shell carries the same Double form.
            let lastConfirmedAt: Double?
        }
        let shell = Shell(
            canonicalName: canonicalName,
            quantity: quantity,
            lastConfirmedAt: lastConfirmedAt?.timeIntervalSinceReferenceDate
        )
        let bytes = try JSONEncoder().encode(shell)
        return try FLJSON.canonicalDecoder().decode(PantrySummaryLine.self, from: bytes)
    }
}
