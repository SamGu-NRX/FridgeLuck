import XCTest
@testable import FLSubstitutions

/// The table validator: every pair cited, references resolvable, difference
/// text honest, conflicts recorded. A violation here fails loudly.
final class SchemaValidationTests: XCTestCase {
    func testTableDecodesAndValidates() throws {
        XCTAssertNoThrow(try Fixtures.table())
    }

    func testEveryPairIsCitedFromTheRegistry() throws {
        let table = try Fixtures.table()
        let sourceIDs = Set(table.sources.map(\.id))
        XCTAssertGreaterThanOrEqual(table.sources.count, 10, "source registry implausibly small")
        for pair in table.pairs {
            XCTAssertFalse(pair.sourceIDs.isEmpty, "pair \(pair.id) has no citation")
            for sourceID in pair.sourceIDs {
                XCTAssertTrue(
                    sourceIDs.contains(sourceID),
                    "pair \(pair.id) cites unknown source \(sourceID)"
                )
            }
        }
    }

    func testEverySourceRecordCarriesTitleAndRetrievalDate() throws {
        let table = try Fixtures.table()
        for source in table.sources {
            XCTAssertFalse(source.title.isEmpty, "source \(source.id) has no title")
            XCTAssertFalse(source.publisher.isEmpty, "source \(source.id) has no publisher")
            // A retrieval date starts the field; a parenthetical provenance
            // note (e.g. "2026-10-10 (PR #49)") may follow it.
            let datePart = String(source.retrieved.prefix(10))
            let parts = datePart.split(separator: "-").map(String.init)
            XCTAssertEqual(parts.map(\.count), [4, 2, 2], "source \(source.id): retrieved must start YYYY-MM-DD")
            if source.retrieved.count > 10 {
                let suffix = String(source.retrieved.dropFirst(10))
                XCTAssertTrue(
                    suffix.hasPrefix(" (") && suffix.hasSuffix(")"),
                    "source \(source.id): trailing provenance must be parenthetical"
                )
            }
        }
    }

    func testTableCoversAtLeast250PairsAcrossAllElevenRoles() throws {
        let table = try Fixtures.table()
        XCTAssertGreaterThanOrEqual(table.pairs.count, 250)
        XCTAssertEqual(Set(table.pairs.map(\.role)), Set(Role.allCases))
    }

    func testDifferenceTextNeverPromisesNoChange() throws {
        let table = try Fixtures.table()
        let forbiddenPhrases = [
            "no change",
            "no difference",
            "exactly the same",
            "tastes the same",
            "indistinguishable",
        ]
        for pair in table.pairs {
            let text = pair.difference.lowercased()
            for phrase in forbiddenPhrases {
                XCTAssertFalse(
                    text.contains(phrase),
                    "pair \(pair.id) promises no change: contains '\(phrase)'"
                )
            }
        }
    }

    func testKnownEvidenceConflictsAreRecordedNotResolved() throws {
        let table = try Fixtures.table()
        // PR #49's two explicit discrepancies must stay visible as conflicts.
        let egg = try Fixtures.pair(table, id: "egg-binder-to-mashed-banana")
        XCTAssertEqual(egg.ratio.status, .conflict)
        XCTAssertTrue(try XCTUnwrap(egg.ratio.conflictWith).contains("0.6"))
        let honey = try Fixtures.pair(table, id: "honey-sweetener-to-banana")
        XCTAssertEqual(honey.ratio.status, .conflict)
        XCTAssertNotNil(honey.ratio.conflictWith)
    }

    func testUnknownIngredientThrowsRatherThanGuessing() throws {
        let table = try Fixtures.table()
        XCTAssertThrowsError(try table.resolveIngredientKey("unicorn root"))
        XCTAssertThrowsError(
            try table.swaps(for: "unicorn root", role: .fat, restrictions: [])
        )
    }

    func testUnknownRestrictionThrowsRatherThanBeingDropped() throws {
        let table = try Fixtures.table()
        XCTAssertThrowsError(
            try table.swaps(for: "egg", role: .binder, restrictions: ["kosher"])
        )
    }
}
