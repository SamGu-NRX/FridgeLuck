import CoreGraphics
import FLFeatureLogic
import GRDB
import XCTest
import Vision

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
    XCTAssertTrue(result.diagnostics.requestFailures.isEmpty)
    XCTAssertTrue(result.diagnostics.passErrors.isEmpty)
    XCTAssertEqual(Set(result.detections.map(\.ingredientId)), [7, 27])
    XCTAssertEqual(result.detections.first { $0.ingredientId == 7 }?.source, .vision)
    XCTAssertEqual(result.detections.first { $0.ingredientId == 27 }?.source, .ocr)
  }

  private actor RequestGate {
    private(set) var classificationCalls = 0
    private(set) var textCalls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func classify() { classificationCalls += 1 }
    func recognizeText() { textCalls += 1 }

    func wait() async {
      if released { return }
      await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
      released = true
      waiting.forEach { $0.resume() }
      waiting.removeAll()
    }
  }

  private struct CancellingResolver: IngredientCatalogResolving {
    func resolve(_ rawValue: String, matching: IngredientCatalogMatching) -> Int64? {
      // Resolution runs after both requests return and before the next crop starts.
      withUnsafeCurrentTask { $0?.cancel() }
      return nil
    }
    func resolveFromText(_ rawText: String) -> Int64? { nil }
    func displayName(for ingredientId: Int64) -> String? { nil }
  }

  func testCancellationDuringFirstCropStopsBothRequestsAndStartsNoFurtherCrop() async throws {
    let db = try makeDatabase()
    let inputImage = try image(side: 128)
    let started = expectation(description: "Both first-crop requests started")
    started.expectedFulfillmentCount = 2
    let calls = RequestGate()
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { _ in
        await calls.classify()
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        return []
      },
      textRequest: { _ in
        await calls.recognizeText()
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        return []
      })
    let scan = Task { try await service.scan(image: inputImage) }
    await fulfillment(of: [started], timeout: 5)
    scan.cancel()
    do {
      _ = try await scan.value
      XCTFail("Cancellation must not return a result")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    let classificationCalls = await calls.classificationCalls
    let textCalls = await calls.textCalls
    XCTAssertEqual(classificationCalls, 1)
    XCTAssertEqual(textCalls, 1)
  }

  func testCancellationAfterRequestsReturnIgnoresSuccessAndOrdinaryFailures() async throws {
    // Injected requests may ignore cancellation. The scan must still discard their results.
    for requestsFail in [false, true] {
      let db = try makeDatabase()
      let inputImage = try image(side: 128)
      let started = expectation(description: "Both requests reached the gate")
      started.expectedFulfillmentCount = 2
      let gate = RequestGate()
      let service = VisionService(
        learningService: LearningService(db: db),
        ingredientResolver: IngredientCatalogResolver(db: db),
        classificationRequest: { _ in
          await gate.classify()
          started.fulfill()
          await gate.wait()
          if requestsFail { throw RequestError.classificationUnavailable }
          return [.init(identifier: "tomato", confidence: 0.8)]
        },
        textRequest: { _ in
          await gate.recognizeText()
          started.fulfill()
          await gate.wait()
          if requestsFail { throw RequestError.textUnavailable }
          return []
        })
      let scan = Task { try await service.scan(image: inputImage) }
      await fulfillment(of: [started], timeout: 5)
      scan.cancel()
      await gate.release()
      do {
        _ = try await scan.value
        XCTFail("Cancelled requests must not produce a result or pipelineFailed")
      } catch {
        XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
      }
      let classificationCalls = await gate.classificationCalls
      let textCalls = await gate.textCalls
      XCTAssertEqual(classificationCalls, 1)
      XCTAssertEqual(textCalls, 1)
    }
  }

  func testCancellationBetweenCropsStartsNoFurtherRequest() async throws {
    let db = try makeDatabase()
    let inputImage = try image(side: 128)
    let calls = RequestGate()
    let service = VisionService(
      learningService: LearningService(db: db), ingredientResolver: CancellingResolver(),
      classificationRequest: { _ in
        await calls.classify()
        return [.init(identifier: "unmapped cancellation test label", confidence: 0.8)]
      },
      textRequest: { _ in
        await calls.recognizeText()
        return []
      })
    let scan = Task { try await service.scan(image: inputImage) }
    do {
      _ = try await scan.value
      XCTFail("Cancellation during crop resolution must stop the scan")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    let classificationCalls = await calls.classificationCalls
    let textCalls = await calls.textCalls
    XCTAssertEqual(classificationCalls, 1)
    XCTAssertEqual(textCalls, 1)
  }

  func testRequestCancellationErrorsNeverBecomePipelineFailures() async throws {
    for cancelClassification in [false, true] {
      for visionError in [false, true] {
        let db = try makeDatabase()
        let inputImage = try image(side: 128)
        let cancellation: any Error = visionError
          ? NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)
          : CancellationError()
        let service = VisionService(
          learningService: LearningService(db: db),
          ingredientResolver: IngredientCatalogResolver(db: db),
          classificationRequest: { _ in
            if cancelClassification { throw cancellation }
            throw RequestError.classificationUnavailable
          },
          textRequest: { _ in
            if !cancelClassification { throw cancellation }
            throw RequestError.textUnavailable
          })
        do {
          _ = try await service.scan(image: inputImage)
          XCTFail("Request cancellation must throw CancellationError")
        } catch {
          XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
      }
    }
  }

  func testAlreadyCancelledScanStartsNoRequestsEvenWithNoInputs() async throws {
    let db = try makeDatabase()
    let calls = RequestGate()
    let inputImage = try image(side: 128)
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { _ in await calls.classify(); return [] },
      textRequest: { _ in await calls.recognizeText(); return [] })
    let sessions: [[ScanInput]] = [
      [], [.init(image: inputImage, source: .camera, captureIndex: 0)],
    ]
    for inputs in sessions {
      let scan = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.scan(inputs: inputs)
      }
      do {
        _ = try await scan.value
        XCTFail("An already-cancelled scan must not return a result")
      } catch {
        XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
      }
    }
    let classificationCalls = await calls.classificationCalls
    let textCalls = await calls.textCalls
    XCTAssertEqual(classificationCalls, 0)
    XCTAssertEqual(textCalls, 0)
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
