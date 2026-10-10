import FLBarcode
import XCTest

/// Catalog binding: a clear winner binds, near-ties stay ambiguous (first-class), weak
/// or absent candidates stay unbound. Never a silent guess.
final class CatalogBindingTests: XCTestCase {
  func testEmptyCandidatesAreUnbound() {
    XCTAssertEqual(CatalogBinder.bind([]), .unbound)
  }

  func testSingleStrongCandidateBinds() {
    let binding = CatalogBinder.bind([CatalogCandidate(id: 1, name: "egg", score: 0.95)])
    XCTAssertEqual(binding, .bound(id: 1, name: "egg", score: 0.95))
  }

  func testWeakCandidateStaysUnbound() {
    // Below minScore: offering this would be a guess.
    let binding = CatalogBinder.bind([CatalogCandidate(id: 1, name: "egg", score: 0.7)])
    XCTAssertEqual(binding, .unbound)
  }

  func testScoreExactlyAtMinScoreBinds() {
    let binding = CatalogBinder.bind([CatalogCandidate(id: 3, name: "milk", score: 0.8)])
    XCTAssertEqual(binding, .bound(id: 3, name: "milk", score: 0.8))
  }

  /// Two plausible foods within the separation margin: ambiguous, not auto-bound.
  func testNearTieIsAmbiguous() {
    let binding = CatalogBinder.bind([
      CatalogCandidate(id: 1, name: "tomato", score: 0.9),
      CatalogCandidate(id: 2, name: "pasta", score: 0.85),
    ])
    guard case .ambiguous(let candidates) = binding else {
      return XCTFail("expected ambiguous, got \(binding)")
    }
    XCTAssertEqual(candidates.count, 2)
    XCTAssertEqual(candidates.first?.id, 1)
  }

  func testExactTieIsAmbiguous() {
    let binding = CatalogBinder.bind([
      CatalogCandidate(id: 7, name: "apple", score: 0.9),
      CatalogCandidate(id: 2, name: "pear", score: 0.9),
    ])
    guard case .ambiguous(let candidates) = binding else {
      return XCTFail("expected ambiguous, got \(binding)")
    }
    // Deterministic order: equal scores sort by id.
    XCTAssertEqual(candidates.map(\.id), [2, 7])
  }

  func testClearSeparationBindsBest() {
    let binding = CatalogBinder.bind([
      CatalogCandidate(id: 2, name: "yogurt", score: 0.93),
      CatalogCandidate(id: 1, name: "cheese", score: 0.6),
    ])
    XCTAssertEqual(binding, .bound(id: 2, name: "yogurt", score: 0.93))
  }

  /// Incoming candidate order never changes the outcome.
  func testOrderInvariance() {
    let a = CatalogBinder.bind([
      CatalogCandidate(id: 1, name: "onion", score: 0.95),
      CatalogCandidate(id: 2, name: "leek", score: 0.88),
    ])
    let b = CatalogBinder.bind([
      CatalogCandidate(id: 2, name: "leek", score: 0.88),
      CatalogCandidate(id: 1, name: "onion", score: 0.95),
    ])
    XCTAssertEqual(a, b)
  }

  /// Separation exactly at the margin still binds (strictly-less-than comparison).
  func testSeparationBoundary() {
    let binding = CatalogBinder.bind([
      CatalogCandidate(id: 1, name: "rice", score: 0.9),
      CatalogCandidate(id: 2, name: "bulgur", score: 0.82),
    ])
    XCTAssertEqual(binding, .bound(id: 1, name: "rice", score: 0.9))
  }
}
