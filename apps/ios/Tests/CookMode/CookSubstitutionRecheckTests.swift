import FLFeatureLogic
import XCTest

/// Pins `CookSubstitutionRecheck` to the receipt contract's exact bytes
/// (`docs/spec/lechef/contracts/receipt.schema.json`'s `allergenRecheck`):
/// verdict from the enum, the eaters screened, and the blocked path when
/// refused. The canonical JSON is what the phone embeds verbatim in every
/// substitution receipt, so these pins are the wire bytes, not a convenience.
final class CookSubstitutionRecheckTests: XCTestCase {
  func testCleanScreenEncodesTheContractBytesWithANullBlockedPath() {
    XCTAssertEqual(
      CookSubstitutionRecheck(verdict: .verified, eaters: ["household"], blockedPath: nil)
        .canonicalJSON,
      "{\"verdict\":\"verified\",\"eaters\":[\"household\"],\"blockedPath\":null}")
  }

  func testBlockedScreenNamesThePathWithTheVerdict() {
    XCTAssertEqual(
      CookSubstitutionRecheck(
        verdict: .unsupported, eaters: ["Ana"], blockedPath: "Contains wheat via soy sauce"
      ).canonicalJSON,
      "{\"verdict\":\"unsupported\",\"eaters\":[\"Ana\"],\"blockedPath\":\"Contains wheat via soy sauce\"}"
    )
  }

  func testUnknownCompositionSaysTheCompositionIsUnknown() {
    XCTAssertEqual(
      CookSubstitutionRecheck.unknownComposition(eaters: ["household"]).canonicalJSON,
      "{\"verdict\":\"unknown\",\"eaters\":[\"household\"],\"blockedPath\":\"composition unknown\"}"
    )
    XCTAssertEqual(
      CookSubstitutionRecheck.unknownComposition(eaters: ["household"], because: "no table")
        .canonicalJSON,
      "{\"verdict\":\"unknown\",\"eaters\":[\"household\"],\"blockedPath\":\"composition unknown: no table\"}"
    )
  }

  func testPlausibleVerdictIsACleanScreenToo() {
    let recheck = CookSubstitutionRecheck(
      verdict: .plausible, eaters: ["you", "Ada"], blockedPath: nil)
    XCTAssertEqual(
      recheck.canonicalJSON,
      "{\"verdict\":\"plausible\",\"eaters\":[\"you\",\"Ada\"],\"blockedPath\":null}",
      "eaters keep the caller's order; blockedPath is present even when null")
  }

  func testQuotesInNamesAndPathsCannotBreakTheReceiptBytes() {
    XCTAssertEqual(
      CookSubstitutionRecheck(
        verdict: .unsupported, eaters: ["Ana \"Q\""], blockedPath: "Contains \"wheat\" via soy"
      ).canonicalJSON,
      "{\"verdict\":\"unsupported\",\"eaters\":[\"Ana \\\"Q\\\"\"],\"blockedPath\":\"Contains \\\"wheat\\\" via soy\"}"
    )
  }

  func testAllowsSwapOnlyForCleanVerdicts() {
    XCTAssertTrue(
      CookSubstitutionRecheck(verdict: .verified, eaters: [], blockedPath: nil).allowsSwap)
    XCTAssertTrue(
      CookSubstitutionRecheck(verdict: .plausible, eaters: [], blockedPath: nil).allowsSwap)
    XCTAssertFalse(
      CookSubstitutionRecheck(verdict: .unknown, eaters: [], blockedPath: "composition unknown")
        .allowsSwap)
    XCTAssertFalse(
      CookSubstitutionRecheck(
        verdict: .unsupported, eaters: [], blockedPath: "Contains wheat via soy sauce"
      ).allowsSwap)
  }
}
