import FLFeatureLogic
import XCTest

/// Hardening tests for `RecommendationPolicy`.
///
/// Complements the base `RecommendationPolicyTests` with pins the base suite does
/// not cover: the exact fallback ID contents, passthrough edge cases (single,
/// large, negative, fallback-sized inputs), and the full widen-decision truth
/// table over the counts the engine can actually observe.
///
/// Assumption note for `fallbackIngredientIDs` ({1, 2, 5, 6}): referential
/// integrity against the live ingredient database cannot be verified from this
/// pure-logic test target. As of this writing, IDs 1, 2, 5, 6 exist in the
/// seeded catalog (`apps/ios/Resources/data.json`: egg, rice, onion, garlic).
/// If the seed catalog is ever renumbered, this pin must be updated
/// deliberately — not silenced.
final class RecommendationPolicyHardeningTests: XCTestCase {
  // MARK: - fallbackIngredientIDs

  func testFallbackIngredientIDsArePinnedToSeedStaples() {
    // Pinning the exact contents so any change to the fallback set is a
    // deliberate, reviewed decision: these IDs are sent to the recipe query
    // whenever a scan detects nothing.
    XCTAssertEqual(RecommendationPolicy.fallbackIngredientIDs, [1, 2, 5, 6])
  }

  func testFallbackIngredientIDsAreNonEmptySoTheFallbackPathIsMeaningful() {
    // If the fallback ever became empty, effectiveIngredientIDs(from: []) would
    // be a no-op and the engine would query with no ingredients at all —
    // silently returning zero recommendations instead of staples.
    XCTAssertFalse(RecommendationPolicy.fallbackIngredientIDs.isEmpty)
  }

  // MARK: - effectiveIngredientIDs passthrough

  func testEffectiveIngredientIDsPassthroughSingleElementSet() {
    XCTAssertEqual(RecommendationPolicy.effectiveIngredientIDs(from: [7]), [7])
  }

  func testEffectiveIngredientIDsPassthroughVeryLargeIDs() {
    let large: Set<Int64> = [Int64.max, Int64.max - 1, 900_000_000]
    XCTAssertEqual(RecommendationPolicy.effectiveIngredientIDs(from: large), large)
  }

  func testEffectiveIngredientIDsPassthroughNegativeIDsUnfiltered() {
    // The policy trusts caller-supplied IDs verbatim: it never filters, clamps,
    // or remaps. If a remap ever becomes desired, it must be a policy change,
    // not a silent one.
    XCTAssertEqual(
      RecommendationPolicy.effectiveIngredientIDs(from: [-1, -999]),
      [-1, -999]
    )
  }

  func testEffectiveIngredientIDsNeverUnionsFallbackIntoDetectedSet() {
    // Guards against a plausible regression: unioning the fallback into every
    // result so fallback recipes "always show". Detected IDs must fully
    // replace the fallback, not be augmented by it.
    XCTAssertEqual(RecommendationPolicy.effectiveIngredientIDs(from: [3]), [3])
    XCTAssertEqual(RecommendationPolicy.effectiveIngredientIDs(from: [3, 4]), [3, 4])
  }

  func testEffectiveIngredientIDsStableWhenInputEqualsFallbackContents() {
    // A detected set that coincides with the fallback is non-empty and must
    // pass through unchanged (no re-resolution, no duplication concerns).
    XCTAssertEqual(
      RecommendationPolicy.effectiveIngredientIDs(from: RecommendationPolicy.fallbackIngredientIDs),
      RecommendationPolicy.fallbackIngredientIDs
    )
  }

  func testEffectiveIngredientIDsPreservesEveryElementOfLargeDetectedSet() {
    let detected = Set<Int64>((1...1000).map { $0 * 3 })
    let effective = RecommendationPolicy.effectiveIngredientIDs(from: detected)
    XCTAssertEqual(effective, detected)
    XCTAssertEqual(effective.count, 1000)
  }

  // MARK: - nearMatchLimit

  func testNearMatchLimitsAreStrictlyPositiveSoAnEmptyCountMeansNoRows() {
    // Both limits must stay >= 1: the engine compares post-limit counts. A
    // positive limit can only trim a result set to a non-empty one, so a
    // returned count of zero always means the query found no rows.
    XCTAssertTrue(RecommendationPolicy.nearMatchLimit(hasExactMatches: true) > 0)
    XCTAssertTrue(RecommendationPolicy.nearMatchLimit(hasExactMatches: false) > 0)
  }

  func testNearMatchLimitWithoutExactMatchesIsAtLeastTheCondensedLimit() {
    // Near matches carry the whole result set when nothing matches exactly, so
    // their budget must never shrink below the condensed one.
    XCTAssertGreaterThanOrEqual(
      RecommendationPolicy.nearMatchLimit(hasExactMatches: false),
      RecommendationPolicy.nearMatchLimit(hasExactMatches: true)
    )
  }

  // MARK: - shouldWidenNearMatchSearch

  func testShouldNotWidenWhenBothTiersHaveResults() {
    // The both-nonzero case is not covered by the base tests; it is exactly
    // where an inverted or "widen when few results" refactor would break.
    XCTAssertFalse(RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 1, nearMatchCount: 1))
    XCTAssertFalse(RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 2, nearMatchCount: 3))
    XCTAssertFalse(
      RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 20, nearMatchCount: 20)
    )
  }

  func testShouldNotWidenWhenOnlyExactTierIsAtItsEngineLimit() {
    // exact saturated at the engine's limit-20 query with zero near matches:
    // widening only re-queries the near tier, so it cannot help the exact tier.
    XCTAssertFalse(
      RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 20, nearMatchCount: 0)
    )
  }

  func testShouldNotWidenWhenOnlyNearTierIsAtItsEngineLimit() {
    // Near matches exist, so there is something to show; widening is reserved
    // for the total-empty case.
    XCTAssertFalse(
      RecommendationPolicy.shouldWidenNearMatchSearch(exactCount: 0, nearMatchCount: 20)
    )
  }

  func testWidenFiresOnlyAtDoubleZeroAcrossTheEngineReachableCountDomain() {
    // The engine passes POST-LIMIT counts: `exact.count` comes from a limit-20
    // query and `near.count` from a limit-8-or-20 query. Because both limits
    // are >= 1, a post-limit count of zero can only mean the query returned no
    // rows — a "limit hit" would still yield a non-empty count. Widening is
    // therefore the "no candidates at all" escape hatch (retry at
    // maxMissingRequired: 2), not a limit-hit handler, and must fire ONLY at
    // (0, 0) over the reachable domain 0...20 for each count.
    for exactCount in 0...20 {
      for nearCount in 0...20 {
        XCTAssertEqual(
          RecommendationPolicy.shouldWidenNearMatchSearch(
            exactCount: exactCount,
            nearMatchCount: nearCount
          ),
          exactCount == 0 && nearCount == 0,
          "widen must be true only at (0, 0); violated at (\(exactCount), \(nearCount))"
        )
      }
    }
  }
}
