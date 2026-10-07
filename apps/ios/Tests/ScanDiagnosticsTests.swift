import FLFeatureLogic
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
      passErrors: ScanDiagnostics.cropPassErrors(
        captureIndex: 2, cropID: "topLeft", classificationError: classificationError,
        ocrError: ocrError),
      elapsedMs: 10,
      requestFailures: ScanDiagnostics.requestFailures(
        captureIndex: 2, cropID: "topLeft", classificationError: classificationError,
        ocrError: ocrError))
  }

  func testClassificationFailureRemainsVisibleWhenOCRSucceeds() {
    let result = diagnostics(
      classificationError: RequestError.classificationUnavailable, ocrError: nil)
    XCTAssertEqual(result.classificationFailureCount, 1)
    XCTAssertEqual(result.ocrFailureCount, 0)
    XCTAssertTrue(result.passErrors.isEmpty)
    XCTAssertEqual(
      result.requestFailures,
      [
        .init(
          captureIndex: 2, cropID: "topLeft", kind: .classification,
          message: "classificationUnavailable")
      ])
  }

  func testOCRFailureRemainsVisibleWhenClassificationSucceeds() {
    let result = diagnostics(classificationError: nil, ocrError: RequestError.textUnavailable)
    XCTAssertEqual(result.classificationFailureCount, 0)
    XCTAssertEqual(result.ocrFailureCount, 1)
    XCTAssertTrue(result.passErrors.isEmpty)
    XCTAssertEqual(result.requestFailures.first?.kind, .ocr)
    XCTAssertEqual(result.requestFailures.first?.message, "textUnavailable")
  }

  func testBothFailuresProduceTwoRequestsAndTheOriginalCropError() {
    let result = diagnostics(
      classificationError: RequestError.classificationUnavailable,
      ocrError: RequestError.textUnavailable)
    XCTAssertEqual(
      result.passErrors,
      ["capture=2,crop=topLeft:class=classificationUnavailable,ocr=textUnavailable"])
    XCTAssertEqual(result.requestFailures.count, 2)
    XCTAssertEqual(result.classificationFailureCount, 1)
    XCTAssertEqual(result.ocrFailureCount, 1)
  }

  func testSuccessfulRequestsProduceNoFailures() {
    let result = diagnostics(classificationError: nil, ocrError: nil)
    XCTAssertTrue(result.passErrors.isEmpty)
    XCTAssertTrue(result.requestFailures.isEmpty)
    XCTAssertEqual(result.classificationFailureCount, 0)
    XCTAssertEqual(result.ocrFailureCount, 0)
  }

  func testTypedFailuresSurviveCoding() throws {
    let original = diagnostics(
      classificationError: RequestError.classificationUnavailable, ocrError: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ScanDiagnostics.self, from: data)
    XCTAssertEqual(decoded.requestFailures, original.requestFailures)
    XCTAssertEqual(decoded.classificationFailureCount, 1)
    XCTAssertEqual(decoded.ocrFailureCount, 0)
  }

  func testOldDiagnosticsDecodeWithNoRequestFailures() throws {
    let original = diagnostics(
      classificationError: RequestError.classificationUnavailable,
      ocrError: RequestError.textUnavailable)
    let decoded = try JSONDecoder().decode(ScanDiagnostics.self, from: legacyData(original))
    XCTAssertEqual(decoded.passErrors, original.passErrors)
    XCTAssertTrue(decoded.requestFailures.isEmpty)
  }

  func testCountsAccumulateAcrossCropsAndCaptures() {
    let failures =
      ScanDiagnostics.requestFailures(
        captureIndex: 0, cropID: "full",
        classificationError: RequestError.classificationUnavailable, ocrError: nil)
      + ScanDiagnostics.requestFailures(
        captureIndex: 1, cropID: "center",
        classificationError: RequestError.classificationUnavailable,
        ocrError: RequestError.textUnavailable)
    let result = ScanDiagnostics(
      captureCount: 2, cropCount: 2, topRawLabels: [], ocrCandidates: [],
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0), passErrors: [], elapsedMs: 0,
      requestFailures: failures)
    XCTAssertEqual(result.classificationFailureCount, 2)
    XCTAssertEqual(result.ocrFailureCount, 1)
    XCTAssertEqual(failures[0].captureIndex, 0)
    XCTAssertEqual(failures[1].cropID, "center")
  }

  func testCountsUseKindsRatherThanErrorMessageContents() {
    let result = ScanDiagnostics(
      captureCount: 1, cropCount: 1, topRawLabels: [], ocrCandidates: [],
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0), passErrors: [], elapsedMs: 0,
      requestFailures: [
        .init(
          captureIndex: 0, cropID: "full", kind: .ocr,
          message: ",request=classification:misleading error text")
      ])
    XCTAssertEqual(result.classificationFailureCount, 0)
    XCTAssertEqual(result.ocrFailureCount, 1)
  }

  func testSiblingSuccessStillProducesAValidBenchmarkRun() {
    let result = diagnostics(
      classificationError: RequestError.classificationUnavailable, ocrError: nil)
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: .init(
        id: "partial-request", resourceName: "unused", resourceExtension: "png",
        scenarioTags: [], expectedIngredientIds: [27]),
      runs: [
        .init(
          iteration: 0, detections: [.init(ingredientId: 27, bucket: .auto)],
          elapsedMs: result.elapsedMs, passErrors: result.passErrors,
          requestFailures: result.requestFailures)
      ],
      gates: .init(
        minimumDetectionF1: 1, minimumCorrectionCoverage: 1,
        minimumOCRFieldAccuracy: 1, minimumReliabilityJaccard: 1, targetMedianElapsedMs: 1000))
    XCTAssertEqual(report.runs.first?.valid, true)
    XCTAssertEqual(report.runs.first?.requestFailures, result.requestFailures)
  }

  func testOldScanRunRecordDecodesWithNoRequestFailures() throws {
    let record = makeRecord()
    let decoded = try JSONDecoder().decode(ScanRunRecord.self, from: legacyData(record))
    XCTAssertEqual(decoded.passErrors, record.passErrors)
    XCTAssertTrue(decoded.requestFailures.isEmpty)
    XCTAssertEqual(decoded.classificationFailureCount, 0)
  }

  func testScanRunStorePersistsFailuresAcrossReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("runs.json")
    let store = ScanRunStore(fileURL: url)
    let original = diagnostics(
      classificationError: RequestError.classificationUnavailable, ocrError: nil)
    await store.record(
      mode: .live, inputSources: [.photoLibrary], provenance: .realScan,
      diagnostics: original, detections: [])
    let records = await ScanRunStore(fileURL: url).recent()
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(record.requestFailures, original.requestFailures)
    XCTAssertTrue(record.passErrors.isEmpty)
    XCTAssertEqual(record.classificationFailureCount, 1)
    XCTAssertEqual(record.ocrFailureCount, 0)
  }

  func testOldBenchmarkObservationAndReportDecodeWithNoRequestFailures() throws {
    let observation = ScanBenchmarkRunObservation(iteration: 0, detections: [], elapsedMs: 0)
    let decoded = try JSONDecoder().decode(
      ScanBenchmarkRunObservation.self, from: legacyData(observation))
    XCTAssertTrue(decoded.requestFailures.isEmpty)
    let report = ScanBenchmarkRunReport(
      iteration: 0, ingredientIds: [], alternativeIngredientIds: [],
      elapsedMs: 0, valid: true, invalidReason: nil, errorDescription: nil, passErrors: [])
    let decodedReport = try JSONDecoder().decode(
      ScanBenchmarkRunReport.self, from: legacyData(report))
    XCTAssertTrue(decodedReport.requestFailures.isEmpty)
  }

  private func makeRecord() -> ScanRunRecord {
    ScanRunRecord(
      id: UUID(), createdAt: Date(), runMode: .live, inputSources: [.camera],
      provenance: .realScan, captureCount: 1, cropCount: 1, elapsedMs: 0,
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0), passErrors: ["old crop error"],
      detections: [])
  }

  private func legacyData<T: Encodable>(_ value: T) throws -> Data {
    let data = try JSONEncoder().encode(value)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "requestFailures")
    return try JSONSerialization.data(withJSONObject: json)
  }
}
