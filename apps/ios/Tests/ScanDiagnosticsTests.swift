import FLFeatureLogic
import Foundation
import XCTest
import Testing

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
    XCTAssertEqual(decoded.outcome, .completed)
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
    XCTAssertEqual(record.outcome, .completed)
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
    json.removeValue(forKey: "outcome")
    return try JSONSerialization.data(withJSONObject: json)
  }
}

struct FailedScanRecordingTests {
  private struct ScanError: LocalizedError {
    var errorDescription: String? { "Test scan failed" }
  }

  private func pipelineError() -> VisionService.VisionServiceError {
    let failures = [0, 1].flatMap { captureIndex in
      ["full", "center"].flatMap { cropID in
        ScanDiagnostics.requestFailures(
          captureIndex: captureIndex, cropID: cropID,
          classificationError: ScanError(), ocrError: ScanError())
      }
    }
    return .pipelineFailed(
      classificationError: ScanError(), ocrError: ScanError(),
      passErrors: ["both requests failed"], requestFailures: failures)
  }

  @Test func legacyRecordWithoutOutcomeDecodesAsCompleted() throws {
    let original = ScanRunRecord(
      id: UUID(), createdAt: Date(), runMode: .live, inputSources: [.camera],
      provenance: .realScan, captureCount: 1, cropCount: 1, elapsedMs: 17,
      bucketCounts: .init(auto: 0, confirm: 0, possible: 0),
      passErrors: ["old crop error"], detections: [],
      requestFailures: pipelineError().requestFailures)
    let data = try JSONEncoder().encode(original)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "outcome")
    let legacyData = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(ScanRunRecord.self, from: legacyData)
    #expect(decoded.outcome == .completed)
    #expect(decoded.requestFailures == original.requestFailures)
    #expect(decoded.passErrors == original.passErrors)
  }

  @Test func pipelineFailureProducesRecordInputs() throws {
    let error = pipelineError()
    let inputs = try #require(ScanRunRecord.failureInputs(
      error: error, captureCount: 2, elapsedMs: 123))
    #expect(inputs.diagnostics.outcome == .failed(message: error.localizedDescription))
    #expect(inputs.diagnostics.passErrors == error.passErrors)
    #expect(inputs.diagnostics.requestFailures == error.requestFailures)
    #expect(inputs.diagnostics.captureCount == 2)
    #expect(inputs.diagnostics.cropCount == 4)
    #expect(inputs.diagnostics.elapsedMs == 123)
    #expect(inputs.diagnostics.topRawLabels.isEmpty)
    #expect(inputs.diagnostics.ocrCandidates.isEmpty)
    #expect(inputs.diagnostics.bucketCounts.auto == 0)
    #expect(inputs.diagnostics.bucketCounts.confirm == 0)
    #expect(inputs.diagnostics.bucketCounts.possible == 0)
    #expect(inputs.detections.isEmpty)
  }

  @Test func cancellationProducesNoRecordInputs() {
    #expect(ScanRunRecord.failureInputs(
      error: CancellationError(), captureCount: 1, elapsedMs: 12) == nil)
  }

  @Test func otherErrorProducesFailedRecordWithoutRequestFailures() throws {
    let inputs = try #require(ScanRunRecord.failureInputs(
      error: ScanError(), captureCount: 1, elapsedMs: 17))
    #expect(inputs.diagnostics.outcome == .failed(message: "Test scan failed"))
    #expect(inputs.diagnostics.passErrors.isEmpty)
    #expect(inputs.diagnostics.requestFailures.isEmpty)
    #expect(inputs.diagnostics.cropCount == 0)
    #expect(inputs.diagnostics.elapsedMs == 17)
    #expect(inputs.detections.isEmpty)
  }

  @Test @MainActor func dependencyRecordsFailureAcrossStoreReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("runs.json")
    let store = ScanRunStore(fileURL: url)
    let dependencies = ScanView.Dependencies(
      loadDemoPayload: { _ in fatalError("This test must not load demo data") },
      scanInputs: { _ in fatalError("This test must not run Vision") },
      recordRun: { mode, sources, provenance, diagnostics, detections in
        await store.record(
          mode: mode, inputSources: sources, provenance: provenance,
          diagnostics: diagnostics, detections: detections)
      })
    let error = pipelineError()
    await dependencies.recordFailedRun(
      error: error, mode: .live, inputSources: [.camera, .photoLibrary],
      provenance: .realScan, elapsedMs: 123)
    let records = await ScanRunStore(fileURL: url).recent()
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.outcome == .failed(message: error.localizedDescription))
    #expect(record.passErrors == error.passErrors)
    #expect(record.requestFailures == error.requestFailures)
    #expect(record.classificationFailureCount == 4)
    #expect(record.ocrFailureCount == 4)
    #expect(record.runMode == .live)
    #expect(record.inputSources == [.camera, .photoLibrary])
    #expect(record.provenance == .realScan)
    #expect(record.captureCount == 2)
    #expect(record.cropCount == 4)
    #expect(record.elapsedMs == 123)
    #expect(record.detections.isEmpty)
    #expect(record.bucketCounts.auto == 0)
    #expect(record.bucketCounts.confirm == 0)
    #expect(record.bucketCounts.possible == 0)

    await dependencies.recordFailedRun(
      error: CancellationError(), mode: .live, inputSources: [.camera],
      provenance: .realScan, elapsedMs: 10)
    #expect(await ScanRunStore(fileURL: url).recent().count == 1)

    await dependencies.recordFailedRun(
      error: ScanError(), mode: .live, inputSources: [.camera],
      provenance: .realScan, elapsedMs: 17)
    let reloaded = await ScanRunStore(fileURL: url).recent()
    #expect(reloaded.count == 2)
    let genericFailure = try #require(reloaded.first)
    #expect(genericFailure.outcome == .failed(message: "Test scan failed"))
    #expect(genericFailure.requestFailures.isEmpty)
    #expect(genericFailure.detections.isEmpty)
  }
}
