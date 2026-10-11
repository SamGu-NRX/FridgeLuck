import XCTest
@testable import FLSubstitutions

/// The safety sweep: ALL pairs x ALL restriction sets. A lookup must never
/// offer a swap whose substitute carries a class the eater's restriction
/// forbids — compound expansion included.
final class AllergySweepTests: XCTestCase {
    func testZeroAllergenIntroducingSuggestionsAcrossAllPairsAndRestrictions() throws {
        let table = try Fixtures.table()
        var refusalChecks = 0

        for restrictionName in table.restrictionNames {
            let restrictionSet = try RestrictionSet(names: [restrictionName], table: table)
            for pair in table.pairs {
                let substitute = try XCTUnwrap(table.ingredient(pair.substitute), pair.id)
                let violating = substitute.classes.filter { restrictionSet.forbidden.contains($0) }

                for role in Fixtures.connectedRoles(pair) {
                    let offered = try table.swaps(for: pair.original, role: role, restrictions: [restrictionName])

                    // A clean pair MAY be offered; a violating pair must not be.
                    guard !violating.isEmpty else { continue }
                    XCTAssertFalse(
                        offered.contains { $0.pair.id == pair.id },
                        "\(restrictionName): \(pair.id) offered while substitute carries "
                            + violating.map(\.rawValue).joined(separator: ",")
                    )

                    // The refusal must be visible in the candidate list too,
                    // with the violated classes named.
                    let candidates = try table.swapCandidates(
                        for: pair.original, role: role, restrictions: [restrictionName]
                    )
                    let candidate = candidates.first { $0.pair.id == pair.id }
                    let observed = try XCTUnwrap(candidate, "\(restrictionName): \(pair.id) missing from candidates")
                    XCTAssertTrue(observed.isRefused, "\(restrictionName): \(pair.id) not refused")
                    XCTAssertEqual(observed.recheck.violated, sortedClasses(violating))
                    refusalChecks += 1
                }
            }
        }
        XCTAssertGreaterThan(refusalChecks, 100, "sweep never exercised refusals — the test would be vacuous")
    }

    func testUnrestrictedLookupsNeverRefuseAnything() throws {
        let table = try Fixtures.table()
        for pair in table.pairs {
            for role in Fixtures.connectedRoles(pair) {
                let candidates = try table.swapCandidates(for: pair.original, role: role, restrictions: [])
                let candidate = try XCTUnwrap(
                    candidates.first { $0.pair.id == pair.id },
                    "\(pair.id) missing from unrestricted candidates"
                )
                XCTAssertFalse(candidate.isRefused, "\(pair.id) refused with no restrictions set")
            }
        }
    }

    func testVerifiedSwapsRespectRestrictionsToo() throws {
        let table = try Fixtures.table()
        for restrictionName in table.restrictionNames {
            let restrictionSet = try RestrictionSet(names: [restrictionName], table: table)
            for original in ["butter", "egg", "soy sauce", "fish sauce"] {
                for swap in try table.verifiedSwaps(for: original, restrictions: [restrictionName]) {
                    let substitute = try XCTUnwrap(table.ingredient(swap.pair.substitute), swap.pair.id)
                    let violating = substitute.classes.filter { restrictionSet.forbidden.contains($0) }
                    XCTAssertTrue(
                        violating.isEmpty,
                        "\(restrictionName): \(swap.pair.id) verified for a restricted eater despite \(violating.map(\.rawValue))"
                    )
                    XCTAssertFalse(swap.isRefused)
                }
            }
        }
    }
}
