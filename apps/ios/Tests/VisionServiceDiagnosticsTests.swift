import CoreGraphics
import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

final class VisionServiceDiagnosticsTests: XCTestCase {
  private enum RequestError: Error {
    case classificationUnavailable
    case textUnavailable
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return db
  }

  private func image(side: Int = 64) throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
  }

  func testSiblingSuccessReturnsDetectionsAndKeepsTheBenchmarkValid() async throws {
    let db = try makeDatabase()
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { _ in throw RequestError.classificationUnavailable },
      textRequest: { _ in [.init(candidates: ["BLACK BEANS"], boundingBox: .zero)] })
    let result = try await service.scan(image: image())
    XCTAssertEqual(result.detections.map(\.ingredientId), [27])
    XCTAssertTrue(result.diagnostics.passErrors.isEmpty)
    XCTAssertEqual(result.diagnostics.classificationFailureCount, result.diagnostics.cropCount)
    XCTAssertEqual(result.diagnostics.ocrFailureCount, 0)
    let report = benchmarkReport(
      detections: [.init(ingredientId: 27, bucket: .auto)],
      passErrors: result.diagnostics.passErrors, failures: result.diagnostics.requestFailures,
      error: nil)
    XCTAssertEqual(report.runs.first?.valid, true)
    XCTAssertEqual(report.runs.first?.requestFailures.count, result.diagnostics.cropCount)
  }

  func testFullyFailedScanThrowsEveryRequestFailureAndTheRunnerRecordsThem() async throws {
    let db = try makeDatabase()
    let inputImage = try image()
    let cropCount = ScanImagePreprocessor.deterministicCrops(for: inputImage).count
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { _ in throw RequestError.classificationUnavailable },
      textRequest: { _ in throw RequestError.textUnavailable })
    do {
      _ = try await service.scan(inputs: [
        .init(image: inputImage, source: .benchmark, captureIndex: 3)
      ])
      XCTFail("A session with no successful requests must still throw")
    } catch let error as VisionService.VisionServiceError {
      XCTAssertEqual(error.requestFailures.count, cropCount * 2)
      XCTAssertEqual(error.passErrors.count, cropCount)
      XCTAssertTrue(error.requestFailures.allSatisfy { $0.captureIndex == 3 })
      XCTAssertEqual(Set(error.requestFailures.map(\.kind)), [.classification, .ocr])
      let observation = ScanBenchmarkRunner.failedObservation(error: error, elapsedMs: 10)
      XCTAssertEqual(observation.requestFailures, error.requestFailures)
      XCTAssertEqual(observation.passErrors, error.passErrors)
      let report = benchmarkReport(
        detections: [], passErrors: observation.passErrors,
        failures: observation.requestFailures, error: observation.errorDescription)
      XCTAssertEqual(report.runs.first?.valid, false)
      XCTAssertEqual(report.runs.first?.requestFailures, error.requestFailures)
    }
  }

  func testMultiCropScanSuppressesCatalogBeanPartsButKeepsClassification() async throws {
    // The crop schedule requires quadrants of at least 64 pixels, so a 64-pixel input tests only the full frame.
    let inputImage = try image(side: 128)
    let fullWidth = inputImage.width
    XCTAssertEqual(ScanImagePreprocessor.deterministicCrops(for: inputImage).count, 6)
    let db = try makeDatabase()
    try await db.write { db in
      try db.execute(
        sql:
          "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (169960, 'Shellie Beans (Canned)', 0, 0, 0, 0)"
      )
      try db.execute(
        sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (169960, 'beans')")
    }
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { _ in [.init(identifier: "tomato", confidence: 0.8)] },
      textRequest: { crop in
        if crop.width == fullWidth { return [.init(candidates: ["BEANS"], boundingBox: .zero)] }
        return [
          .init(
            candidates: ["BLACK"], boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.05)),
          .init(
            candidates: ["BEANS"], boundingBox: CGRect(x: 0.2, y: 0.44, width: 0.2, height: 0.05)),
        ]
      })
    let result = try await service.scan(image: inputImage)
    XCTAssertEqual(result.diagnostics.cropCount, 6)
    XCTAssertEqual(Set(result.detections.map(\.ingredientId)), [7, 27])
    XCTAssertEqual(result.detections.first { $0.ingredientId == 7 }?.source, .vision)
    XCTAssertEqual(result.detections.first { $0.ingredientId == 27 }?.source, .ocr)
  }

  private func benchmarkReport(
    detections: [ScanBenchmarkObservedDetection], passErrors: [String],
    failures: [FLFeatureLogic.ScanRequestFailure], error: String?
  ) -> ScanBenchmarkImageReport {
    ScanBenchmarkScorer.evaluateImage(
      corpusEntry: .init(
        id: "requests", resourceName: "unused", resourceExtension: "png",
        scenarioTags: [], expectedIngredientIds: [27]),
      runs: [
        .init(
          iteration: 0, detections: detections, elapsedMs: 10, passErrors: passErrors,
          errorDescription: error, requestFailures: failures)
      ],
      gates: .init(
        minimumDetectionF1: 1, minimumCorrectionCoverage: 1,
        minimumOCRFieldAccuracy: 1, minimumReliabilityJaccard: 1, targetMedianElapsedMs: 1000))
  }
}
