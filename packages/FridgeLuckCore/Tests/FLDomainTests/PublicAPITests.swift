import XCTest
import FLDomain

// Deliberately WITHOUT @testable: this file compiles against the public API
// only. Review round 1, item 7 — PantrySummaryLine's validated initializer is
// public, so external modules (and tests without @testable) build summary
// lines through the same validation decoding uses.

final class PublicAPITests: XCTestCase {
    func testPantrySummaryLineIsConstructibleWithoutTestableImport() throws {
        let confirmedAt = try FLTimestamp.decode("2026-10-10T09:30:00.000Z", target: "test")
        let line = try AssistantContextSnapshot.PantrySummaryLine(
            canonicalName: "flour",
            quantity: .unknown,
            lastConfirmedAt: confirmedAt
        )
        XCTAssertEqual(line.canonicalName, "flour")
        XCTAssertTrue(line.quantity.isUnknown)
        XCTAssertEqual(line.lastConfirmedAt, confirmedAt)

        XCTAssertThrowsError(
            try AssistantContextSnapshot.PantrySummaryLine(canonicalName: "   ", quantity: .unknown, lastConfirmedAt: nil),
            "the public initializer applies the same non-empty rule as decoding"
        )
    }
}
