import XCTest
@testable import FLSubstitutions

enum Fixtures {
    struct MissingPair: Error {
        let id: String
    }

    /// The canonical in-repo table. Validation runs on every load; a bad
    /// table fails here, loudly.
    static func table() throws -> SubstitutionTable {
        try SubstitutionTable.loadDefault()
    }

    static func pair(_ table: SubstitutionTable, id: String) throws -> Pair {
        guard let pair = table.pairs.first(where: { $0.id == id }) else {
            throw MissingPair(id: id)
        }
        return pair
    }

    /// Every role a pair is connected to: its primary role plus anything
    /// recorded under supported_also or fails.
    static func connectedRoles(_ pair: Pair) -> Set<Role> {
        var roles: Set<Role> = [pair.role]
        roles.formUnion(pair.supportedAlso.map(\.role))
        roles.formUnion(pair.fails.map(\.role))
        return roles
    }

    /// Deterministic serialization of a ranked candidate list, including
    /// rank order. Used by the byte-identical determinism test.
    static func canonical(_ candidates: [SwapCandidate]) -> String {
        candidates.map { candidate in
            let recheck = candidate.recheck
            return [
                candidate.pair.id,
                candidate.requestedRole.rawValue,
                String(describing: candidate.verdict),
                recheck.originalClasses.map(\.rawValue).joined(separator: ","),
                recheck.substituteClasses.map(\.rawValue).joined(separator: ","),
                recheck.introduced.map(\.rawValue).joined(separator: ","),
                recheck.removed.map(\.rawValue).joined(separator: ","),
                recheck.violated.map(\.rawValue).joined(separator: ","),
                candidate.ratio.status.rawValue,
                String(format: "%.4f", candidate.ratio.value),
            ].joined(separator: "|")
        }
        .joined(separator: "\n")
    }

    /// Deterministic lookup battery: a fixed set of originals (first ten
    /// sorted distinct originals, plus the compound-allergen protagonists).
    static func lookupBattery(_ table: SubstitutionTable) -> [String] {
        var originals = Array(Array(Set(table.pairs.map(\.original))).sorted().prefix(10))
        originals.append(contentsOf: ["egg", "soy_sauce", "butter", "fish_sauce"])
        return Array(Set(originals)).sorted()
    }

    /// Restriction batteries exercised by determinism and ranking tests.
    static let restrictionBatteries: [[String]] = [
        [],
        ["vegan"],
        ["gluten-free", "dairy-free"],
        ["nut-free", "soy-free", "egg-free"],
    ]
}
