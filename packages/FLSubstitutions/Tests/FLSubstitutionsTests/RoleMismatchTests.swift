import XCTest
@testable import FLSubstitutions

/// A pair must only ever be offered for a role the table connects it to, and
/// recorded failures must surface as unsupported — never as offers.
final class RoleMismatchTests: XCTestCase {
    func testLeaveningPairIsNeverOfferedForGarnishRole() throws {
        let table = try Fixtures.table()
        // Yeast has exactly one pair: leavening. Asked as a garnish there is
        // no row connecting it — nothing may be offered.
        XCTAssertTrue(try table.swapCandidates(for: "active dry yeast", role: .garnish, restrictions: []).isEmpty)
        XCTAssertTrue(try table.swaps(for: "active dry yeast", role: .garnish, restrictions: []).isEmpty)
    }

    func testApplesauceAskedAsLeaveningIsUnsupportedWithTheRecordedReason() throws {
        let table = try Fixtures.table()
        let candidates = try table.swapCandidates(for: "egg", role: .leavening, restrictions: [])
        let candidate = try XCTUnwrap(
            candidates.first { $0.pair.id == "egg-binder-to-applesauce" },
            "egg-binder-to-applesauce should still be a candidate for inspection"
        )
        XCTAssertEqual(candidate.verdict, .unsupported)
        let why = try XCTUnwrap(candidate.pair.fails.first { $0.role == .leavening })
        XCTAssertFalse(why.why.isEmpty, "the recorded failure reason must be present")

        let offered = try table.swaps(for: "egg", role: .leavening, restrictions: [])
        XCTAssertFalse(offered.contains { $0.pair.id == "egg-binder-to-applesauce" })
    }

    func testAquafabaStaysOfferedForLeavening() throws {
        let table = try Fixtures.table()
        let offered = try table.swaps(for: "egg", role: .leavening, restrictions: [])
        XCTAssertTrue(offered.contains { $0.pair.id == "egg-leavening-to-aquafaba" })
        for swap in offered {
            XCTAssertTrue(
                swap.verdict == .verified || swap.verdict == .plausible,
                "\(swap.pair.id) offered with verdict \(swap.verdict)"
            )
        }
    }

    func testRankOrderIsVerdictAscendingAcrossALookupBattery() throws {
        let table = try Fixtures.table()
        for name in ["egg", "butter", "honey", "soy sauce", "fish sauce"] {
            for role in Role.allCases {
                let offered = try table.swaps(for: name, role: role, restrictions: [])
                let verdicts = offered.map(\.verdict)
                XCTAssertEqual(verdicts, verdicts.sorted(), "rank order broken for \(name)/\(role)")
            }
        }
    }

    func testUnsupportedNeverOutranksVerified() throws {
        let table = try Fixtures.table()
        for name in Fixtures.lookupBattery(table) {
            for role in Role.allCases {
                let candidates = try table.swapCandidates(for: name, role: role, restrictions: [])
                let unsupportedRanks = candidates.enumerated()
                    .filter { $0.element.verdict == .unsupported }
                    .map(\.offset)
                let verifiedRanks = candidates.enumerated()
                    .filter { $0.element.verdict == .verified }
                    .map(\.offset)
                if let worst = unsupportedRanks.max(), let best = verifiedRanks.min() {
                    XCTAssertLessThan(best, worst, "\(name)/\(role): unsupported outranks verified")
                }
            }
        }
    }
}
