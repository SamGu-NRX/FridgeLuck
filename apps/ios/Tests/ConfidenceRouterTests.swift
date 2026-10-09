import Foundation
import XCTest

@testable import FridgeLuck

/// Pins ConfidenceRouter behavior: per-source routing thresholds, inclusive
/// boundary values, explanation strings, bucket labels, categorize ordering,
/// and the Detection convenience flags. The implementation is treated as
/// correct; these tests exist to catch regressions.
class ConfidenceRouterTests: XCTestCase {

  // MARK: - Helpers

  private func makeDetection(
    confidence: Float,
    source: DetectionSource,
    ocrMatchKind: OCRMatchKind? = nil,
    label: String = "Milk"
  ) -> Detection {
    Detection(
      ingredientId: 1,
      label: label,
      confidence: confidence,
      source: source,
      originalVisionLabel: label,
      ocrMatchKind: ocrMatchKind
    )
  }

  private func assertBucket(
    _ expected: ConfidenceBucket,
    for confidence: Float,
    source: DetectionSource,
    ocrMatchKind: OCRMatchKind? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let detection = makeDetection(
      confidence: confidence, source: source, ocrMatchKind: ocrMatchKind)
    XCTAssertEqual(
      ConfidenceRouter.bucket(for: detection),
      expected,
      "confidence \(confidence), source \(source), matchKind \(String(describing: ocrMatchKind))",
      file: file,
      line: line)
  }

  // MARK: - Routing thresholds

  func testVisionThresholdsAndBoundaries() {
    assertBucket(.auto, for: 0.82, source: .vision)  // exactly at visionAuto
    assertBucket(.confirm, for: ConfidenceRouter.Thresholds.visionAuto.nextDown, source: .vision)
    assertBucket(.confirm, for: 0.45, source: .vision)  // exactly at visionConfirmMin
    assertBucket(
      .possible, for: ConfidenceRouter.Thresholds.visionConfirmMin.nextDown, source: .vision)
    assertBucket(.auto, for: 1.0, source: .vision)
    assertBucket(.possible, for: 0.0, source: .vision)
  }

  func testOCRExactThresholdsAndBoundaries() {
    assertBucket(.auto, for: 0.90, source: .ocr, ocrMatchKind: .exact)  // exactly at ocrExactAuto
    assertBucket(
      .confirm, for: ConfidenceRouter.Thresholds.ocrExactAuto.nextDown, source: .ocr,
      ocrMatchKind: .exact)
    assertBucket(
      .confirm, for: 0.60, source: .ocr, ocrMatchKind: .exact)  // exactly at ocrExactConfirmMin
    assertBucket(
      .possible, for: ConfidenceRouter.Thresholds.ocrExactConfirmMin.nextDown, source: .ocr,
      ocrMatchKind: .exact)
    assertBucket(.auto, for: 1.0, source: .ocr, ocrMatchKind: .exact)
  }

  func testOCRFuzzyThresholdsAndNeverAuto() {
    assertBucket(
      .confirm, for: 0.55, source: .ocr, ocrMatchKind: .fuzzy)  // exactly at ocrFuzzyConfirmMin
    assertBucket(
      .possible, for: ConfidenceRouter.Thresholds.ocrFuzzyConfirmMin.nextDown, source: .ocr,
      ocrMatchKind: .fuzzy)
    assertBucket(.confirm, for: 1.0, source: .ocr, ocrMatchKind: .fuzzy)  // fuzzy never auto
    assertBucket(.confirm, for: 0.90, source: .ocr, ocrMatchKind: .fuzzy)
  }

  func testOCRNilMatchKindUsesExactRules() {
    // nil matchKind falls back to .exact, so 0.90 is auto...
    assertBucket(.auto, for: 0.90, source: .ocr, ocrMatchKind: nil)
    // ...and 0.55 is possible under exact rules even though fuzzy at 0.55 is confirm.
    let fuzzy = makeDetection(confidence: 0.55, source: .ocr, ocrMatchKind: .fuzzy)
    let nilKind = makeDetection(confidence: 0.55, source: .ocr, ocrMatchKind: nil)
    XCTAssertEqual(ConfidenceRouter.bucket(for: fuzzy), .confirm)
    XCTAssertEqual(ConfidenceRouter.bucket(for: nilKind), .possible)
    XCTAssertNotEqual(
      ConfidenceRouter.bucket(for: fuzzy),
      ConfidenceRouter.bucket(for: nilKind),
      "fuzzy and nil matchKind must route differently at 0.55")
    assertBucket(
      .possible, for: ConfidenceRouter.Thresholds.ocrExactConfirmMin.nextDown, source: .ocr,
      ocrMatchKind: nil)
  }

  func testManualSourceAlwaysAuto() {
    assertBucket(.auto, for: 0.0, source: .manual)
    assertBucket(.auto, for: 1.0, source: .manual)
    assertBucket(.auto, for: 0.5, source: .manual)
  }

  // MARK: - Pinned constants

  func testThresholdConstantsArePinned() {
    XCTAssertEqual(ConfidenceRouter.Thresholds.visionAuto, 0.82)
    XCTAssertEqual(ConfidenceRouter.Thresholds.visionConfirmMin, 0.45)
    XCTAssertEqual(ConfidenceRouter.Thresholds.ocrExactAuto, 0.90)
    XCTAssertEqual(ConfidenceRouter.Thresholds.ocrExactConfirmMin, 0.60)
    XCTAssertEqual(ConfidenceRouter.Thresholds.ocrFuzzyConfirmMin, 0.55)
  }

  // MARK: - Categorize

  func testCategorizePreservesOrderAndBuckets() {
    let d0 = makeDetection(confidence: 0.9, source: .vision, label: "d0")
    let d1 = makeDetection(confidence: 0.7, source: .ocr, ocrMatchKind: .fuzzy, label: "d1")
    let d2 = makeDetection(confidence: 0.3, source: .vision, label: "d2")
    let d3 = makeDetection(confidence: 0.95, source: .ocr, ocrMatchKind: .exact, label: "d3")
    let d4 = makeDetection(confidence: 1.0, source: .manual, label: "d4")

    let result = ConfidenceRouter.categorize([d0, d1, d2, d3, d4])

    XCTAssertEqual(result.confirmed.map(\.label), ["d0", "d3", "d4"])
    XCTAssertEqual(result.needsConfirmation.map(\.label), ["d1"])
    XCTAssertEqual(result.possible.map(\.label), ["d2"])

    let allLabels = (result.confirmed + result.needsConfirmation + result.possible)
      .map(\.label)
      .sorted()
    XCTAssertEqual(allLabels, ["d0", "d1", "d2", "d3", "d4"])
  }

  // MARK: - Explanations

  func testExplanationStringsExact() {
    XCTAssertEqual(
      ConfidenceRouter.explanation(for: makeDetection(confidence: 0.5, source: .vision)),
      "Vision score 50% from whole-image classification; used for routing only (not a guarantee).")
    XCTAssertEqual(
      ConfidenceRouter.explanation(
        for: makeDetection(confidence: 0.75, source: .ocr, ocrMatchKind: .exact)),
      "OCR exact token match, routed with high trust at 75% score (still reviewable).")
    XCTAssertEqual(
      ConfidenceRouter.explanation(
        for: makeDetection(confidence: 0.6, source: .ocr, ocrMatchKind: .fuzzy)),
      "OCR fuzzy token match at 60% score; confirmation recommended before auto-use.")
    XCTAssertEqual(
      ConfidenceRouter.explanation(for: makeDetection(confidence: 0.99, source: .manual)),
      "Manual confirmation (trusted user input).")
  }

  func testExplanationScoreRounds() {
    // 0.9999 * 100 rounds to 100.
    XCTAssertEqual(
      ConfidenceRouter.explanation(for: makeDetection(confidence: 0.9999, source: .vision)),
      "Vision score 100% from whole-image classification; used for routing only (not a guarantee).")
    // 0.678 * 100 = 67.8, which rounds to 68.
    XCTAssertEqual(
      ConfidenceRouter.explanation(
        for: makeDetection(confidence: 0.678, source: .ocr, ocrMatchKind: .exact)),
      "OCR exact token match, routed with high trust at 68% score (still reviewable).")
  }

  func testExplanationForNilMatchKindUsesExactWording() {
    XCTAssertEqual(
      ConfidenceRouter.explanation(
        for: makeDetection(confidence: 0.75, source: .ocr, ocrMatchKind: nil)),
      "OCR exact token match, routed with high trust at 75% score (still reviewable).")
  }

  // MARK: - Labels and convenience flags

  func testBucketLabels() {
    XCTAssertEqual(ConfidenceRouter.label(for: .auto), "Auto")
    XCTAssertEqual(ConfidenceRouter.label(for: .confirm), "Confirm")
    XCTAssertEqual(ConfidenceRouter.label(for: .possible), "Possible")
  }

  func testDetectionConvenienceFlags() {
    let high = makeDetection(confidence: 0.9, source: .vision)
    XCTAssertEqual(ConfidenceRouter.bucket(for: high), .auto)
    XCTAssertTrue(high.isHighConfidence)
    XCTAssertFalse(high.isMediumConfidence)
    XCTAssertFalse(high.isLowConfidence)

    let medium = makeDetection(confidence: 0.5, source: .vision)
    XCTAssertEqual(ConfidenceRouter.bucket(for: medium), .confirm)
    XCTAssertFalse(medium.isHighConfidence)
    XCTAssertTrue(medium.isMediumConfidence)
    XCTAssertFalse(medium.isLowConfidence)

    let low = makeDetection(confidence: 0.3, source: .vision)
    XCTAssertEqual(ConfidenceRouter.bucket(for: low), .possible)
    XCTAssertFalse(low.isHighConfidence)
    XCTAssertFalse(low.isMediumConfidence)
    XCTAssertTrue(low.isLowConfidence)
  }
}
