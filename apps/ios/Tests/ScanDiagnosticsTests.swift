import Foundation
import XCTest

@testable import FridgeLuck

final class ScanDiagnosticsTests: XCTestCase {
  private enum RequestError: Error {
    case classificationUnavailable
    case textUnavailable
  }

  private func diagnostics(classificationError: Error?, ocrError: Error?) -> ScanDiagnostics {
    ScanDiagnostics(
      captureCount: 1, cropCount: 1, topRawLabels: [], ocrCandidates: ["BLACK BEANS"],
      bucketCounts: .init(auto: 1, confirm: 0, possible: 0),
      passErrors: ScanDiagnostics.requestFailures(
        captureIndex: 2, cropID: "topLeft", classificationError: classificationError, ocrError: ocrError),
      elapsedMs: 10)
  }

  func testClassificationFailureRemainsVisibleWhenOCRSucceeds() {
    let result = diagnostics(classificationError: RequestError.classificationUnavailable, ocrError: nil)
    XCTAssertEqual(result.classificationFailureCount, 1)
    XCTAssertEqual(result.ocrFailureCount, 0)
    XCTAssertEqual(result.passErrors, ["capture=2,crop=topLeft,request=classification:classificationUnavailable"])
  }

  func testOCRFailureRemainsVisibleWhenClassificationSucceeds() {
    let result = diagnostics(classificationError: nil, ocrError: RequestError.textUnavailable)
    XCTAssertEqual(result.classificationFailureCount, 0)
    XCTAssertEqual(result.ocrFailureCount, 1)
    XCTAssertEqual(result.passErrors, ["capture=2,crop=topLeft,request=ocr:textUnavailable"])
  }

  func testBothFailuresProduceTwoRequestRecords() {
    let result = diagnostics(
      classificationError: RequestError.classificationUnavailable, ocrError: RequestError.textUnavailable)
    XCTAssertEqual(result.passErrors.count, 2)
    XCTAssertEqual(result.classificationFailureCount, 1)
    XCTAssertEqual(result.ocrFailureCount, 1)
  }

  func testSuccessfulRequestsProduceNoFailures() {
    let result = diagnostics(classificationError: nil, ocrError: nil)
    XCTAssertTrue(result.passErrors.isEmpty)
    XCTAssertEqual(result.classificationFailureCount, 0)
    XCTAssertEqual(result.ocrFailureCount, 0)
  }

  func testCountsSurviveCodingWithoutChangingTheStoredFormat() throws {
    let original = diagnostics(classificationError: RequestError.classificationUnavailable, ocrError: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ScanDiagnostics.self, from: data)
    XCTAssertEqual(decoded.passErrors, original.passErrors)
    XCTAssertEqual(decoded.classificationFailureCount, 1)
    XCTAssertEqual(decoded.ocrFailureCount, 0)
  }

  func testCountsAccumulateAcrossCropsAndCaptures() {
    let failures = ScanDiagnostics.requestFailures(
      captureIndex: 0, cropID: "full", classificationError: RequestError.classificationUnavailable, ocrError: nil)
      + ScanDiagnostics.requestFailures(
        captureIndex: 1, cropID: "center", classificationError: RequestError.classificationUnavailable,
        ocrError: RequestError.textUnavailable)
    let result = ScanDiagnostics(
      captureCount: 2, cropCount: 2, topRawLabels: [], ocrCandidates: [],
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0), passErrors: failures, elapsedMs: 0)
    XCTAssertEqual(result.classificationFailureCount, 2)
    XCTAssertEqual(result.ocrFailureCount, 1)
    XCTAssertTrue(failures[0].contains("capture=0,crop=full,"))
    XCTAssertTrue(failures[1].contains("capture=1,crop=center,"))
  }
}
