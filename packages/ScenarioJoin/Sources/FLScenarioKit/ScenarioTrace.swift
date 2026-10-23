import Foundation
import FLDomain

// MARK: - Replayable evidence
// Every scenario records one ordered trace line per step. A trace is
// Equatable and canonically JSON-encodable, so a scenario's evidence is
// replayable two ways:
//   1. in-suite: run the scenario twice, compare bytes (determinism);
//   2. against a committed golden trace: a behavior change surfaces as a
//      reviewable diff, never as a silent shift.

public struct ScenarioTrace: Sendable, Equatable {
    public private(set) var lines: [String] = []

    public init() {}

    public mutating func record(_ step: String, _ detail: String) {
        lines.append("\(step): \(detail)")
    }

    public var joined: String {
        lines.joined(separator: "\n")
    }

    public var count: Int { lines.count }

    /// Canonical bytes (sorted keys, ISO 8601 timestamps) — byte-identical
    /// runs produce byte-identical data on any host.
    public func canonicalJSON() throws -> Data {
        try FLJSON.canonicalData(lines)
    }
}
