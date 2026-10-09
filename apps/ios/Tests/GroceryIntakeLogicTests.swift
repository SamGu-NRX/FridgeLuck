import FLFeatureLogic
import XCTest

/// The receipt parser reads amounts without inventing them: explicit weights are measured,
/// counts stay estimates pending a known unit mass, and price-only lines say nothing about
/// grams.
final class GroceryReceiptParsingTests: XCTestCase {
  func testStructuralLinesAreExcludedWithReasons() {
    XCTAssertFalse(GroceryReceiptParser.classify(line: "SUBTOTAL 23.50").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "TOTAL 13.44").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "CASH 20.00").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "VAT 7%").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "12 ITEMS").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "020 7946 0958").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "$4.50").isItem)
    XCTAssertFalse(GroceryReceiptParser.classify(line: "   ").isItem)
  }

  func testKeywordBoundariesDoNotSwallowFoodNames() {
    XCTAssertTrue(GroceryReceiptParser.classify(line: "CASHIERS: 2").isItem)
    XCTAssertTrue(GroceryReceiptParser.classify(line: "GALA APPLES 1.2 KG").isItem)
  }

  func testExplicitWeightsConvertToMeasuredGrams() {
    XCTAssertEqual(GroceryReceiptParser.parseExplicitWeight(in: "454 G")?.grams, 454)
    XCTAssertEqual(GroceryReceiptParser.parseExplicitWeight(in: "0.5 kg")?.grams, 500)
    XCTAssertEqual(GroceryReceiptParser.parseExplicitWeight(in: "12 OZ")?.grams ?? 0, 340.2, accuracy: 0.05)
    XCTAssertEqual(GroceryReceiptParser.parseExplicitWeight(in: "1,25 LB")?.grams ?? 0, 567.0, accuracy: 0.05)
  }

  func testCommaDecimalsWithoutAUnitStayPrices() {
    XCTAssertNil(GroceryReceiptParser.parseExplicitWeight(in: "1,50"))
  }

  func testImplausibleWeightsAreRejected() {
    XCTAssertNil(GroceryReceiptParser.parseExplicitWeight(in: "400000 g"))
  }

  func testCountEvidencePatterns() {
    XCTAssertEqual(GroceryReceiptParser.parseCount(in: "2 @ 3.99"), 2)
    XCTAssertEqual(GroceryReceiptParser.parseCount(in: "x2 MILK"), 2)
    XCTAssertEqual(GroceryReceiptParser.parseCount(in: "2 FOR 5.00"), 2)
    XCTAssertEqual(GroceryReceiptParser.parseCount(in: "2 MILK 3.29"), 2)
    XCTAssertNil(GroceryReceiptParser.parseCount(in: "3.29 MILK"))
  }

  func testExplicitWeightLineIsMeasured() {
    let amount = GroceryReceiptParser.parseAmount(line: "GALA APPLES 1.2 KG @ $4.50")
    XCTAssertEqual(amount?.provenance, .measured)
    XCTAssertEqual(amount?.grams ?? 0, 1200, accuracy: 0.05)
  }

  func testPriceOnlyLineYieldsNoAmount() {
    XCTAssertNil(GroceryReceiptParser.parseAmount(line: "BANANAS $1.99"))
  }

  func testCountLineKeepsCountEvidenceWithoutInventingGrams() {
    let amount = GroceryReceiptParser.parseAmount(line: "2 EGGS $0.90")
    XCTAssertNil(amount?.grams)
    XCTAssertEqual(amount?.count, 2)
    XCTAssertEqual(amount?.provenance, .estimate)
  }

  func testPackagingNetWeightIsMeasured() {
    let amount = GroceryReceiptParser.packagingAmount(in: ["Nutrition Facts", "NET WT 454 G"])
    XCTAssertEqual(amount?.provenance, .measured)
    XCTAssertEqual(amount?.grams ?? 0, 454, accuracy: 0.05)
  }

  func testServingSizesAreNotPackageWeights() {
    XCTAssertNil(GroceryReceiptParser.packagingAmount(in: ["SERVING SIZE 1 CUP", "240g per serving"]))
    XCTAssertNil(GroceryReceiptParser.packagingAmount(in: ["$9.99"]))
  }

  func testUserAmountsWithUnitsAreMeasured() {
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("500g")?.grams, 500)
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("500g")?.provenance, .measured)
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("0,5 kg")?.grams, 500)
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("12 oz")?.grams ?? 0, 340.2, accuracy: 0.05)
  }

  func testPlainUserNumbersAreEnteredValues() {
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("500")?.grams, 500)
    XCTAssertEqual(GroceryIntakeNormalizer.parseUserAmount("500")?.provenance, .entered)
  }

  func testUserAmountsRejectGarbageAndImplausibleValues() {
    XCTAssertNil(GroceryIntakeNormalizer.parseUserAmount("abc"))
    XCTAssertNil(GroceryIntakeNormalizer.parseUserAmount(""))
    XCTAssertNil(GroceryIntakeNormalizer.parseUserAmount("-5"))
    XCTAssertNil(GroceryIntakeNormalizer.parseUserAmount("40000"))
  }

  func testDisplayTitlesStripWeightsPricesAndDanglingAtSigns() {
    XCTAssertEqual(GroceryIntakeNormalizer.displayTitle("GALA APPLES 1.2 KG @ $4.50"), "GALA APPLES")
  }
}

/// Draft normalization turns classified receipt lines and photo detections into review items:
/// measured amounts beat estimates, unknown amounts stay unknown, and unresolvable lines stay
/// unresolved for the user instead of being silently dropped or guessed.
final class GroceryIntakeNormalizationTests: XCTestCase {
  private let receiptLines = [
    "FRESH MARKET",
    "GALA APPLES 1.2 KG @ $4.50",
    "2 EGGS $0.90",
    "BANANAS $1.99",
    "SUBTOTAL 12.50",
    "TOTAL 13.44",
    "CASH 20.00",
    "CHANGE 6.56",
  ]

  private func makeDrafts() -> [GroceryDraftItem] {
    GroceryIntakeNormalizer.draftItems(
      fromReceiptLines: receiptLines,
      resolve: { line in
        if line.contains("APPLES") { return (11, 0.90) }
        if line.contains("EGGS") { return (3, 0.90) }
        if line.contains("BANANAS") { return (2, 0.55) }
        return nil
      },
      alternativesFor: { _ in [GroceryAlternative(id: 99, name: "Fallback Food")] },
      estimateUnitGrams: { id in id == 3 ? 50 : nil },
      inferLocation: { id in id == 11 ? .fridge : .pantry }
    )
  }

  func testItemLinesBecomeDraftsInOrderAndTotalsDropOut() {
    let drafts = makeDrafts()
    XCTAssertEqual(drafts.map(\.ingredientId), [nil, 11, 3, 2])
    XCTAssertFalse(drafts.contains { $0.rawDescription.contains("SUBTOTAL") })
  }

  func testStoreHeaderStaysUnresolvedInsteadOfInvented() {
    let header = makeDrafts()[0]
    XCTAssertNil(header.ingredientId)
    XCTAssertNil(header.amountGrams)
  }

  func testMeasuredWeightCarriesProvenanceEvidenceAndLocation() {
    let apples = makeDrafts()[1]
    XCTAssertEqual(apples.amountGrams ?? 0, 1200, accuracy: 0.05)
    XCTAssertEqual(apples.provenance, .measured)
    XCTAssertEqual(apples.evidenceSummary, "1.2 KG")
    XCTAssertEqual(apples.location, .fridge)
    XCTAssertEqual(apples.confidence, 0.90, accuracy: 0.001)
  }

  func testCountDerivedAmountsMultiplyByUnitMassAndStayEstimates() {
    let eggs = makeDrafts()[2]
    XCTAssertEqual(eggs.amountGrams ?? 0, 100, accuracy: 0.05)
    XCTAssertEqual(eggs.provenance, .estimate)
    XCTAssertEqual(eggs.countEvidence, 2)
  }

  func testPriceOnlyItemsStayUnknownAndUnresolved() {
    let bananas = makeDrafts()[3]
    XCTAssertNil(bananas.amountGrams)
    XCTAssertNil(bananas.provenance)
    XCTAssertEqual(bananas.confidence, 0.55, accuracy: 0.001)
    XCTAssertFalse(bananas.alternatives.isEmpty)
    XCTAssertFalse(bananas.isResolvedForCommit)
  }

  func testSingleProductPhotoPrefersPackagingWeightOverUnitEstimates() {
    let drafts = GroceryIntakeNormalizer.draftItems(
      fromDetections: [GroceryDetectionInput(ingredientId: 7, label: "Milk", confidence: 0.88)],
      ocrText: ["NET WT 454 G"],
      estimateGramsForName: { name in name.lowercased().contains("milk") ? 240 : nil },
      inferLocation: { _ in .fridge }
    )
    XCTAssertEqual(drafts.count, 1)
    XCTAssertEqual(drafts[0].amountGrams ?? 0, 454, accuracy: 0.05)
    XCTAssertEqual(drafts[0].provenance, .measured)
  }

  func testMultiProductPhotosFallBackToUnitEstimates() {
    let drafts = GroceryIntakeNormalizer.draftItems(
      fromDetections: [
        GroceryDetectionInput(ingredientId: 7, label: "Milk", confidence: 0.88),
        GroceryDetectionInput(ingredientId: 3, label: "Eggs", confidence: 0.82),
      ],
      ocrText: ["NET WT 454 G"],
      estimateGramsForName: { name in
        name.lowercased().contains("milk") ? 240 : name.lowercased().contains("eggs") ? 50 : nil
      },
      inferLocation: { _ in .fridge }
    )
    XCTAssertEqual(drafts.count, 2)
    XCTAssertEqual(drafts[0].amountGrams ?? 0, 240, accuracy: 0.05)
    XCTAssertEqual(drafts[0].provenance, .estimate)
    XCTAssertEqual(drafts[1].amountGrams ?? 0, 50, accuracy: 0.05)
  }

  func testFoodsWithoutAKnownUnitMassStayUnknown() {
    let drafts = GroceryIntakeNormalizer.draftItems(
      fromDetections: [GroceryDetectionInput(ingredientId: 3, label: "Rara Vegetable", confidence: 0.8)],
      ocrText: [],
      estimateGramsForName: { _ in nil },
      inferLocation: { _ in .pantry }
    )
    XCTAssertNil(drafts[0].amountGrams)
    XCTAssertNil(drafts[0].provenance)
  }

  func testUnresolvedDetectionsKeepNoIdentityAmountOrLocation() {
    let drafts = GroceryIntakeNormalizer.draftItems(
      fromDetections: [GroceryDetectionInput(ingredientId: nil, label: "Mystery", confidence: 0.5)],
      ocrText: [],
      estimateGramsForName: { _ in nil },
      inferLocation: { _ in .pantry }
    )
    XCTAssertNil(drafts[0].ingredientId)
    XCTAssertNil(drafts[0].amountGrams)
    XCTAssertEqual(drafts[0].location, .unknown)
  }
}
