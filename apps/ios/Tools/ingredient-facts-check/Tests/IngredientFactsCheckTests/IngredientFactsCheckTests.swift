import XCTest

@testable import IngredientFactsLogic

/// Offline checks for the ingredient facts presentation model.
///
/// These run against the exact source file the production `FLFeatureLogic` framework compiles
/// (the logic target is a symlink into `apps/ios/FeatureLogic/IngredientFacts`), so the math
/// verified here is the math the sheet ships.
final class IngredientFactsCheckTests: XCTestCase {
  /// Broccoli-like values; 0.385 g sodium per 100 g converts to a whole 385 mg.
  private static let reference = IngredientFactsRecord(
    energyKilocalories: 89,
    proteinGrams: 3.7,
    carbohydrateGrams: 11.2,
    fatGrams: 0.4,
    fiberGrams: 2.6,
    sugarGrams: 1.7,
    sodiumGrams: 0.385
  )

  private func model(
    _ record: IngredientFactsRecord = IngredientFactsCheckTests.reference
  ) -> IngredientFactsModel {
    IngredientFactsModel(record: record)
  }

  private func portion(
    _ grams: Double,
    _ record: IngredientFactsRecord = IngredientFactsCheckTests.reference
  ) -> IngredientFactsPortion? {
    if case .valid(let portion) = model(record).portionOutcome(forGrams: grams) { return portion }
    return nil
  }

  private func textOutcome(
    _ text: String, _ record: IngredientFactsRecord = IngredientFactsCheckTests.reference
  ) -> IngredientFactsPortionOutcome {
    model(record).portionOutcome(forText: text)
  }

  // MARK: - Reference: conversions and units

  /// Sodium is stored in grams per 100 g and converted to milligrams exactly once.
  func testReferenceConvertsStoredSodiumGramsToMilligramsOnce() {
    let reference = IngredientFactsModel(
      record: IngredientFactsCheckTests.reference
    ).reference
    XCTAssertEqual(reference.sodiumMilligrams, 385)
  }

  /// Stored energy is authoritative: it is carried through untouched, never re-derived
  /// from macro factors (4/4/9 on this record would claim 416.8 kcal, not the stored 89).
  func testReferenceEnergyIsStoredValueNotMacroDerived() {
    let reference = model().reference
    XCTAssertEqual(reference.energyKilocalories, 89)
    XCTAssertEqual(reference.proteinGrams, 3.7)
    XCTAssertEqual(reference.carbohydrateGrams, 11.2)
    XCTAssertEqual(reference.fatGrams, 0.4)
  }

  // MARK: - Portions: presets, fractions, energy authority

  /// 100 g is the identity portion: every displayed value equals the reference exactly.
  func testIdentityPortionAt100GramsEqualsReference() {
    let portion = portion(100)
    XCTAssertNotNil(portion)
    XCTAssertEqual(portion?.grams, 100)
    XCTAssertEqual(portion?.energyKilocalories, 89)
    XCTAssertEqual(portion?.proteinGrams, 3.7)
    XCTAssertEqual(portion?.sodiumMilligrams, 385)
  }

  /// The literal preset controls (50 / 100 / 250 g) parse through the same text path.
  func testLiteralPresetWeightsScaleLinearly() {
    for (text, factor) in [("50", 0.5), ("100", 1.0), ("250", 2.5)] {
      guard case .valid(let portion) = textOutcome(text) else {
        return XCTFail("\(text) g should produce a valid portion")
      }
      XCTAssertEqual(portion.energyKilocalories, 89 * factor, accuracy: 1e-9, text)
      XCTAssertEqual(portion.proteinGrams, 3.7 * factor, accuracy: 1e-9, text)
      XCTAssertEqual(portion.sodiumMilligrams, 385 * factor, accuracy: 1e-9, text)
    }
  }

  /// Fractional grams scale the reference fractionally ("62.5" and decimal comma both).
  func testFractionalGramsScaleFractionally() {
    for text in ["62.5", "62,5"] {
      guard case .valid(let portion) = textOutcome(text) else {
        return XCTFail("\(text) g should produce a valid portion")
      }
      XCTAssertEqual(portion.grams, 62.5)
      XCTAssertEqual(portion.energyKilocalories, 89 * 0.625, accuracy: 1e-9, text)
      XCTAssertEqual(portion.sodiumMilligrams, 385 * 0.625, accuracy: 1e-9, text)
    }
  }

  /// Even when 4/4/9 on the macros would give a wildly different number, portion energy
  /// is the stored energy scaled.
  func testPortionEnergyIsStoredEnergyScaled() {
    let record = IngredientFactsRecord(
      energyKilocalories: 42,
      proteinGrams: 100,
      carbohydrateGrams: 100,
      fatGrams: 100,
      fiberGrams: 0,
      sugarGrams: 0,
      sodiumGrams: 0
    )
    // 4/4/9 would say 1400 kcal per 100 g; the stored value says 42.
    XCTAssertEqual(portion(100, record)?.energyKilocalories, 42)
    XCTAssertEqual(portion(250, record)?.energyKilocalories, 105)
  }

  // MARK: - Invalid input: specific errors, reference untouched

  func testEmptyTextIsAnInvitationNotAnError() {
    for text in ["", "   ", "\n"] {
      XCTAssertEqual(textOutcome(text), .empty, text)
    }
  }

  func testNonNumericTextIsRejectedWithASpecificMessage() {
    for text in ["abc", "1..2", "50g", "g50"] {
      XCTAssertEqual(textOutcome(text), .failed(.notANumber), text)
    }
    XCTAssertTrue(
      IngredientFactsInputError.notANumber.errorMessage.contains("number"),
      "error must tell the user what to enter")
  }

  func testNonFiniteTextIsRejected() {
    for text in ["nan", "inf", "-inf", "1e309"] {
      XCTAssertEqual(textOutcome(text), .failed(.notFinite), text)
    }
    XCTAssertTrue(
      IngredientFactsInputError.notFinite.errorMessage.contains("finite"),
      "error must name the finite requirement")
  }

  func testNonPositiveWeightsAreRejected() {
    for text in ["0", "0.0", "-5"] {
      XCTAssertEqual(textOutcome(text), .failed(.notPositive), text)
    }
    XCTAssertTrue(
      IngredientFactsInputError.notPositive.errorMessage.contains("greater than 0"),
      "error must state the positivity requirement")
  }

  /// A finite weight whose scaled values overflow is rejected rather than displayed as inf.
  func testOverflowingWeightIsRejected() {
    let oily = IngredientFactsRecord(
      energyKilocalories: 5000,
      proteinGrams: 0,
      carbohydrateGrams: 0,
      fatGrams: 0,
      fiberGrams: 0,
      sugarGrams: 0,
      sodiumGrams: 0
    )
    XCTAssertEqual(textOutcome("1e308", oily), .failed(.unsupportedMagnitude))
  }

  /// Every invalid path leaves the reference and record bit-for-bit unchanged.
  func testInvalidAndValidFlowsLeaveReferenceUnchanged() {
    let fresh = model()
    let before = fresh.reference
    let recordBefore = fresh.record

    for text in ["abc", "0", "-5", "1e309", "62.5", ""] {
      _ = fresh.portionOutcome(forText: text)
    }

    XCTAssertEqual(fresh.reference, before)
    XCTAssertEqual(fresh.record, recordBefore)
  }

  /// Reset (back to the empty field) resolves to the invitation again, with the reference intact.
  func testResetReturnsToEmptyWithReferenceIntact() {
    let facts = model()
    guard case .valid = facts.portionOutcome(forText: "250") else {
      return XCTFail("250 g should be valid before reset")
    }
    XCTAssertEqual(facts.portionOutcome(forText: ""), .empty)
    XCTAssertEqual(facts.reference, IngredientFactsModel(record: facts.record).reference)
  }

  // MARK: - Descriptions: supplied vs absent, no invented provenance

  func testDescriptionFreeRecordCarriesNoDescriptionAndNoProvenanceClaim() {
    let facts = model()
    XCTAssertNil(facts.record.suppliedDescription)
    // No error or message anywhere in the model claims a USDA or measured source.
    let allMessages = [
      IngredientFactsInputError.empty.errorMessage,
      IngredientFactsInputError.notANumber.errorMessage,
      IngredientFactsInputError.notFinite.errorMessage,
      IngredientFactsInputError.notPositive.errorMessage,
      IngredientFactsInputError.unsupportedMagnitude.errorMessage,
      IngredientFactsInputError.unsupportedReference.errorMessage,
    ]
    for message in allMessages {
      XCTAssertFalse(message.lowercased().contains("usda"), message)
      XCTAssertFalse(message.lowercased().contains("measured"), message)
    }
  }

  func testSuppliedDescriptionIsCarriedVerbatim() {
    let record = IngredientFactsRecord(
      energyKilocalories: 89,
      proteinGrams: 3.7,
      carbohydrateGrams: 11.2,
      fatGrams: 0.4,
      fiberGrams: 2.6,
      sugarGrams: 1.7,
      sodiumGrams: 0.385,
      suppliedDescription: "A crisp green stalk, best raw or lightly steamed."
    )
    XCTAssertEqual(
      model(record).record.suppliedDescription,
      "A crisp green stalk, best raw or lightly steamed.")
  }

  // MARK: - Unusable stored nutrition

  func testNonFiniteStoredNutritionCannotScaleButReferenceStillShows() {
    let broken = IngredientFactsRecord(
      energyKilocalories: .nan,
      proteinGrams: 1,
      carbohydrateGrams: 1,
      fatGrams: 1,
      fiberGrams: 1,
      sugarGrams: 1,
      sodiumGrams: 1
    )
    let facts = model(broken)
    XCTAssertFalse(facts.reference.isScalable)
    XCTAssertEqual(facts.portionOutcome(forText: ""), .empty)
    XCTAssertEqual(facts.portionOutcome(forText: "150"), .failed(.unsupportedReference))
    XCTAssertEqual(facts.portionOutcome(forGrams: 150), .failed(.unsupportedReference))
  }

  // MARK: - Display formatting

  func testQuantityFormattingMatchesStoredNumberConvention() {
    XCTAssertEqual(IngredientFactsQuantity.grams(2.4), "2.4g")
    XCTAssertEqual(IngredientFactsQuantity.grams(0), "0.0g")
    XCTAssertEqual(IngredientFactsQuantity.kilocalories(120.4), "120 kcal")
    XCTAssertEqual(IngredientFactsQuantity.milligrams(385.4), "385mg")
    XCTAssertEqual(IngredientFactsQuantity.milligrams(240.625), "241mg")
  }

  func testNonFiniteValuesRenderAsEmDash() {
    XCTAssertEqual(IngredientFactsQuantity.grams(.nan), "—")
    XCTAssertEqual(IngredientFactsQuantity.kilocalories(.infinity), "—")
    XCTAssertEqual(IngredientFactsQuantity.milligrams(.nan), "—")
  }
}
