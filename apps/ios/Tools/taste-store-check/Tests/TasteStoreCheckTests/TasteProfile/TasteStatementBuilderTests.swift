import XCTest

@testable import FLFeatureLogic

/// The statement builder's display rules, pinned by docs/spec/taste/SPEC.md §4 and the
/// golden fixture: thresholds with denominators, expiry, correction semantics, and the
/// rule that exposure-only evidence can never produce a statement.
final class TasteStatementBuilderTests: XCTestCase {
  private let featureKey = "ingredient:101"
  private let now = Date(timeIntervalSince1970: 1_792_000_000)

  private func day(_ days: Double) -> Date {
    now.addingTimeInterval(-days * 86_400)
  }

  private func evidence(
    claim: TasteInferredClaim = .lowRating,
    featureKey: String = "ingredient:101",
    name: String = "coriander",
    numerator: Int,
    denominator: Int,
    lastEvidenceAt: Date?
  ) -> TasteFeatureEvidence {
    TasteFeatureEvidence(
      claim: claim, featureKind: .ingredient, featureKey: featureKey, featureName: name,
      numerator: numerator, denominator: denominator, lastEvidenceAt: lastEvidenceAt)
  }

  private func rejectedSeed(
    featureKey: String, claim: TasteInferredClaim = .lowRating
  ) -> TasteStatementSeed {
    let id = TasteStatementIdentity.statementId(
      featureKey: featureKey, templateId: claim.templateStem)
    return TasteStatementSeed(
      id: id, layer: .inferred, featureKind: .ingredient, featureKey: featureKey,
      templateId: "\(claim.templateStem).hedged", state: .rejected,
      createdAt: day(40), updatedAt: day(1), text: "corrected earlier")
  }

  // MARK: - Threshold

  func testStatementAppearsExactlyAtDenominatorThreshold() {
    // 2 bad of 3 cooked: denominator bar met, ratio above 0.6.
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 2, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [], now: now)

    XCTAssertEqual(page.statements(layer: .inferred).count, 1)
    let statement = page.statements(layer: .inferred)[0]
    XCTAssertEqual(statement.numerator, 2)
    XCTAssertEqual(statement.denominator, 3)
    XCTAssertEqual(statement.templateId, "taste.lowrating.confident")
    XCTAssertTrue(page.hidden.isEmpty)
  }

  func testStatementAppearsExactlyAtRatioThreshold() {
    // 3 of 5 is exactly 0.6 — the ratio boundary renders.
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 5, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertEqual(page.statements(layer: .inferred).count, 1)
    XCTAssertTrue(page.hidden.isEmpty)
  }

  func testStatementBelowEitherBarIsHiddenAsThinEvidence() {
    // Ratio below 0.6 despite denominator 3.
    let thinRatio = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 1, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertTrue(thinRatio.statements(layer: .inferred).isEmpty)
    XCTAssertEqual(thinRatio.hidden.count, 1)
    XCTAssertEqual(thinRatio.hidden[0].reason, .thinEvidence)
    XCTAssertEqual(thinRatio.hidden[0].numerator, 1)
    XCTAssertEqual(thinRatio.hidden[0].denominator, 3)

    // Denominator below 3 despite ratio 1.0.
    let thinCount = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 2, denominator: 2, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertTrue(thinCount.statements(layer: .inferred).isEmpty)
    XCTAssertEqual(thinCount.hidden.map(\.reason), [.thinEvidence])
  }

  // MARK: - Hedged and confident wording

  func testHedgedOnlyWhenAllEvidenceIsBadBelowTenDenominators() {
    let hedged = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertEqual(hedged.statements(layer: .inferred)[0].templateId, "taste.lowrating.hedged")
    XCTAssertEqual(
      hedged.statements(layer: .inferred)[0].text,
      "You seem to go off coriander: the last 3 recipes you cooked with it were rated 2 stars or below."
    )

    // All bad but denominator 10+: confident wording, naming both counts.
    let confidentAllBad = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 10, denominator: 10, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertEqual(
      confidentAllBad.statements(layer: .inferred)[0].templateId, "taste.lowrating.confident")
    XCTAssertEqual(
      confidentAllBad.statements(layer: .inferred)[0].text,
      "You go off coriander: 10 of the 10 recipes you cooked with it were rated 2 stars or below."
    )

    // Mixed evidence: confident even below 10, per the spec's over-claim guard (§9).
    let mixed = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 4, denominator: 5, lastEvidenceAt: day(1))],
      seeds: [], now: now)
    XCTAssertEqual(mixed.statements(layer: .inferred)[0].templateId, "taste.lowrating.confident")
  }

  // MARK: - Expiry

  func testStatementRendersExactlyAtStalenessBoundary() {
    // cook_rating half-life 60 days x 3 = 180 days. Exactly at the boundary renders.
    let atBoundary = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(180))],
      seeds: [], now: now)
    XCTAssertEqual(atBoundary.statements(layer: .inferred).count, 1)
    XCTAssertTrue(atBoundary.hidden.isEmpty)
  }

  func testStatementExpiresPastStalenessBoundaryAndRevivesOnFreshEvidence() {
    let staleEvidence = evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(180.01))
    let firstId = TasteStatementIdentity.statementId(
      featureKey: featureKey, templateId: TasteInferredClaim.lowRating.templateStem)
    let storedSeed = TasteStatementSeed(
      id: firstId, layer: .inferred, featureKind: .ingredient, featureKey: featureKey,
      templateId: "taste.lowrating.hedged", numerator: 3, denominator: 3,
      state: .active, createdAt: day(200), updatedAt: day(180), text: "old sentence")

    let expired = TasteStatementBuilder.build(
      evidence: [staleEvidence], seeds: [storedSeed], now: now)
    XCTAssertTrue(expired.statements(layer: .inferred).isEmpty, "expired is a hidden state")
    XCTAssertEqual(expired.hidden.map(\.reason), [.staleEvidence])
    // The stored row is marked expired so the evidence trail stays inspectable.
    XCTAssertEqual(expired.statements.map(\.state), [.expired])

    // Fresh evidence revives it automatically.
    let revived = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [storedSeed], now: now)
    XCTAssertEqual(revived.statements(layer: .inferred).count, 1)
    XCTAssertEqual(revived.statements(layer: .inferred)[0].state, .active)
    XCTAssertEqual(revived.statements(layer: .inferred)[0].createdAt, day(200))
  }

  // MARK: - "This is wrong" vs "Don't ask again"

  func testThisIsWrongRemovesStatementAndItDoesNotReturnFromSameEvidence() {
    let seed = rejectedSeed(featureKey: featureKey)
    // The same strong evidence that produced the statement in the first place.
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [seed], now: now)

    let inferred = page.statements(layer: .inferred)
    XCTAssertEqual(inferred.map(\.state), [.rejected], "kept, never re-learned")
    XCTAssertTrue(inferred.allSatisfy { $0.text == "corrected earlier" })
    XCTAssertTrue(page.hidden.isEmpty, "a rejected statement is corrected, not hidden")
  }

  func testThisIsWrongSurvivesEvenGrowingEvidence() {
    let seed = rejectedSeed(featureKey: featureKey)
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 8, denominator: 9, lastEvidenceAt: day(1))],
      seeds: [seed], now: now)
    XCTAssertEqual(page.statements(layer: .inferred).map(\.state), [.rejected])
  }

  func testDontAskAgainBehavesDifferentlyFromThisIsWrong() {
    let id = TasteStatementIdentity.statementId(
      featureKey: featureKey, templateId: TasteInferredClaim.lowRating.templateStem)
    func mutedSeed(until: Date) -> TasteStatementSeed {
      TasteStatementSeed(
        id: id, layer: .inferred, featureKind: .ingredient, featureKey: featureKey,
        templateId: "taste.lowrating.hedged", numerator: 3, denominator: 3,
        state: .muted, mutedUntil: until, createdAt: day(40), updatedAt: day(1),
        text: "muted sentence")
    }
    let strongEvidence = [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(1))]

    // While the mute holds the statement is carried through as muted — not rendered,
    // not regenerated, and not rejected.
    let whileMuted = TasteStatementBuilder.build(
      evidence: strongEvidence, seeds: [mutedSeed(until: now.addingTimeInterval(86_400))],
      now: now)
    XCTAssertEqual(whileMuted.statements(layer: .inferred).map(\.state), [.muted])

    // Past the mute the statement comes back from the same evidence — unlike a
    // rejected statement, which stays gone.
    let afterMute = TasteStatementBuilder.build(
      evidence: strongEvidence, seeds: [mutedSeed(until: now.addingTimeInterval(-86_400))],
      now: now)
    XCTAssertEqual(afterMute.statements(layer: .inferred).count, 1)
    XCTAssertEqual(afterMute.statements(layer: .inferred)[0].state, .active)
    XCTAssertEqual(
      afterMute.statements(layer: .inferred)[0].text,
      "You seem to go off coriander: the last 3 recipes you cooked with it were rated 2 stars or below."
    )
  }

  // MARK: - Pass-through layers and confirmed state

  func testRestrictionStatedAndPinnedLayersPassThroughUnchanged() {
    let restriction = TasteStatementSeed(
      id: "r1", layer: .restriction, templateId: "restriction.setup.allergy",
      state: .active, createdAt: day(90), updatedAt: day(90),
      text: "No shellfish. Set at setup, edited in setup only.")
    let pinned = TasteStatementSeed(
      id: "p1", layer: .pinned, featureKind: .ingredient, featureKey: "ingredient:207",
      templateId: "pinned.dont_ask_again", state: .muted,
      mutedUntil: now.addingTimeInterval(86_400), pinnedValue: -6.0,
      createdAt: day(30), updatedAt: day(30),
      text: "You asked not to hear about blue cheese again for a while.")
    let page = TasteStatementBuilder.build(
      evidence: [], seeds: [restriction, pinned], now: now)

    XCTAssertEqual(page.statements.count, 2)
    XCTAssertEqual(page.statements(layer: .restriction).first?.text, restriction.text)
    XCTAssertEqual(page.statements(layer: .pinned).first?.pinnedValue, -6.0)
  }

  func testConfirmedStateSurvivesRecompute() {
    let id = TasteStatementIdentity.statementId(
      featureKey: featureKey, templateId: TasteInferredClaim.lowRating.templateStem)
    let seed = TasteStatementSeed(
      id: id, layer: .inferred, featureKind: .ingredient, featureKey: featureKey,
      templateId: "taste.lowrating.hedged", numerator: 3, denominator: 3,
      state: .confirmed, createdAt: day(40), updatedAt: day(2), text: "confirmed sentence")
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(1))],
      seeds: [seed], now: now)
    XCTAssertEqual(page.statements(layer: .inferred)[0].state, .confirmed)
  }

  // MARK: - Availability is not preference

  func testExposureOnlyEvidenceNeverProducesALikeStatement() {
    // All evidence good (numerator 0): the claim hides — and no template in the
    // catalogue produces a "you like" sentence from watching alone.
    let page = TasteStatementBuilder.build(
      evidence: [
        evidence(numerator: 0, denominator: 12, lastEvidenceAt: day(1)),
        evidence(
          claim: .substitutedAway, featureKey: "ingredient:207", name: "blue cheese",
          numerator: 0, denominator: 4, lastEvidenceAt: day(2)),
      ], seeds: [], now: now)
    XCTAssertTrue(page.statements(layer: .inferred).isEmpty)
    XCTAssertTrue(page.statements.allSatisfy { !$0.text.lowercased().contains("you like") })
    XCTAssertEqual(page.hidden.map(\.reason), [.thinEvidence, .thinEvidence])
  }

  func testSubstitutedClaimUsesItsOwnHalfLife() {
    // substitution half-life 45 days x 3 = 135 days: stale past that even though the
    // cook_rating claim at the same recency would not be.
    let page = TasteStatementBuilder.build(
      evidence: [
        evidence(
          claim: .substitutedAway, featureKey: "ingredient:207", name: "blue cheese",
          numerator: 3, denominator: 3, lastEvidenceAt: day(140)),
      ], seeds: [], now: now)
    XCTAssertTrue(page.statements(layer: .inferred).isEmpty)
    XCTAssertEqual(page.hidden.map(\.reason), [.staleEvidence])

    let fresh = TasteStatementBuilder.build(
      evidence: [
        evidence(
          claim: .substitutedAway, featureKey: "ingredient:207", name: "blue cheese",
          numerator: 3, denominator: 3, lastEvidenceAt: day(134)),
      ], seeds: [], now: now)
    XCTAssertEqual(fresh.statements(layer: .inferred)[0].templateId, "taste.substituted.hedged")
  }

  // MARK: - Deterministic identity

  func testStatementIdsAreStableAcrossRecomputes() {
    let first = TasteStatementIdentity.statementId(
      featureKey: "ingredient:101", templateId: "taste.lowrating")
    let second = TasteStatementIdentity.statementId(
      featureKey: "ingredient:101", templateId: "taste.lowrating")
    let other = TasteStatementIdentity.statementId(
      featureKey: "ingredient:207", templateId: "taste.lowrating")
    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, other)
    XCTAssertEqual(first.count, 36, "UUID-shaped id")
  }

  func testGoldenFixtureCaseRendersCorianderStatement() {
    // The golden fixture's statement case: 3 coriander cooks rated 2, 1, 1 within the
    // evidence window, denominator 3 clears the bar, hedged template renders.
    let page = TasteStatementBuilder.build(
      evidence: [evidence(numerator: 3, denominator: 3, lastEvidenceAt: day(9))],
      seeds: [], now: now)
    XCTAssertEqual(page.statements(layer: .inferred)[0].templateId, "taste.lowrating.hedged")
    XCTAssertEqual(page.statements(layer: .inferred)[0].featureKey, "ingredient:101")
    XCTAssertEqual(page.statements(layer: .inferred)[0].numerator, 3)
    XCTAssertEqual(page.statements(layer: .inferred)[0].denominator, 3)
  }
}
