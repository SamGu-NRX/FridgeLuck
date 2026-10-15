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
    case barrierTimedOut
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

  // These barriers block only the detached Vision worker, never the test's async executor.
  private final class WorkerBarrier: @unchecked Sendable {
    let reached: XCTestExpectation
    private let condition = NSCondition()
    private var released = false

    init(_ description: String) {
      reached = XCTestExpectation(description: description)
    }

    func wait() throws {
      condition.lock()
      defer { condition.unlock() }
      reached.fulfill()
      let deadline = Date().addingTimeInterval(10)
      while !released {
        if !condition.wait(until: deadline), !released { throw RequestError.barrierTimedOut }
      }
    }

    func release() {
      condition.lock()
      released = true
      condition.broadcast()
      condition.unlock()
    }
  }

  private final class RecordingVisionRequest: VNClassifyImageRequest, @unchecked Sendable {
    let cancelled = XCTestExpectation(description: "VNRequest.cancel() called")
    private let lock = NSLock()
    private var cancels = 0
    private var performs = 0

    var cancelCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return cancels
    }

    var performCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return performs
    }

    override func cancel() {
      lock.lock()
      cancels += 1
      lock.unlock()
      super.cancel()
      cancelled.fulfill()
    }

    func recordPerform() {
      lock.lock()
      performs += 1
      lock.unlock()
    }
  }

  func testVisionBridgeCancelledBeforeRegistrationSkipsPerform() async throws {
    let inputImage = try image()
    let request = RecordingVisionRequest()
    let barrier = WorkerBarrier("Worker reached the point before registration")
    let operation = Task {
      try await VisionService.runVisionRequest { cancellation in
        try barrier.wait()
        XCTAssertTrue(Task.isCancelled, "Cancellation must also reach the detached worker")
        try cancellation.perform(request, on: inputImage) { _, _ in request.recordPerform() }
        return 1
      }
    }
    await fulfillment(of: [barrier.reached], timeout: 5)
    operation.cancel()
    barrier.release()
    do {
      _ = try await operation.value
      XCTFail("The bridge must discard cancelled work")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertEqual(request.performCount, 0)
    XCTAssertEqual(request.cancelCount, 0, "No request was registered to cancel")

    // Test the registration latch separately from the detached worker's cancellation flag.
    let cancellation = VisionService.VisionRequestCancellation()
    cancellation.cancel()
    XCTAssertThrowsError(
      try cancellation.perform(request, on: inputImage) { _, _ in request.recordPerform() }
    ) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(request.performCount, 0)
  }

  func testVisionBridgeCancellationAfterRegistrationBeforeHandlerWorkCancelsRequest() async throws {
    let inputImage = try image()
    let request = RecordingVisionRequest()
    let barrier = WorkerBarrier("Request registered, handler work not started")
    let operation = Task {
      try await VisionService.runVisionRequest { cancellation in
        try cancellation.perform(request, on: inputImage) { registered, _ in
          XCTAssertTrue(registered === request)
          try barrier.wait()
          // Model a Vision handler rejecting a request cancelled before its work begins.
          if request.cancelCount > 0 {
            throw NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)
          }
          request.recordPerform()
        }
        return 1
      }
    }
    await fulfillment(of: [barrier.reached], timeout: 5)
    operation.cancel()
    await fulfillment(of: [request.cancelled], timeout: 5)
    XCTAssertEqual(request.cancelCount, 1)
    barrier.release()
    do {
      _ = try await operation.value
      XCTFail("A registered request must not return a result after cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertEqual(request.performCount, 0)
    XCTAssertEqual(request.cancelCount, 1)
  }

  func testVisionBridgeInFlightCancellationReachesRequestAndAbortsScan() async throws {
    let db = try makeDatabase()
    let inputImage = try image(side: 128)
    let request = RecordingVisionRequest()
    let barrier = WorkerBarrier("Vision handler is in flight")
    let calls = RequestGate()
    let service = VisionService(
      learningService: LearningService(db: db),
      ingredientResolver: IngredientCatalogResolver(db: db),
      classificationRequest: { crop in
        await calls.classify()
        return try await VisionService.runVisionRequest { cancellation in
          try cancellation.perform(request, on: crop) { registered, _ in
            XCTAssertTrue(registered === request)
            request.recordPerform()
            try barrier.wait()
            // An ordinary handler error after cancellation must not become scan diagnostics.
            throw RequestError.classificationUnavailable
          }
          return []
        }
      },
      textRequest: { _ in await calls.recognizeText(); return [] })
    let scan = Task { try await service.scan(image: inputImage) }
    await fulfillment(of: [barrier.reached], timeout: 5)
    scan.cancel()
    await fulfillment(of: [request.cancelled], timeout: 5)
    XCTAssertEqual(request.cancelCount, 1, "Scan cancellation must reach VNRequest.cancel()")
    barrier.release()
    do {
      _ = try await scan.value
      XCTFail("Cancelled Vision work must not produce a scan result or failure diagnostics")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertEqual(request.performCount, 1)
    XCTAssertEqual(request.cancelCount, 1)
    let classificationCalls = await calls.classificationCalls
    XCTAssertEqual(classificationCalls, 1, "No later crop may start")
  }

  func testVisionBridgeCancellationAfterCompletionDiscardsResult() async throws {
    let inputImage = try image()
    let request = RecordingVisionRequest()
    let barrier = WorkerBarrier("Handler completed and unregistered, result not returned")
    let operation = Task {
      try await VisionService.runVisionRequest { cancellation in
        try cancellation.perform(request, on: inputImage) { _, _ in request.recordPerform() }
        try barrier.wait()
        return 42
      }
    }
    await fulfillment(of: [barrier.reached], timeout: 5)
    operation.cancel()
    barrier.release()
    do {
      _ = try await operation.value
      XCTFail("A completed result must still be discarded after task cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertEqual(request.performCount, 1)
    XCTAssertEqual(request.cancelCount, 0, "Completed requests must be unregistered")
  }

  func testVisionBridgeNormalizesVisionCancellationWithoutTaskCancellation() async throws {
    let inputImage = try image()
    let request = RecordingVisionRequest()
    do {
      _ = try await VisionService.runVisionRequest { cancellation in
        try cancellation.perform(request, on: inputImage) { _, _ in
          request.recordPerform()
          throw NSError(domain: VNErrorDomain, code: VNErrorCode.requestCancelled.rawValue)
        }
        return 1
      }
      XCTFail("Vision's cancellation error must be normalized by the bridge")
    } catch {
      XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
    }
    XCTAssertFalse(Task.isCancelled)
    XCTAssertEqual(request.performCount, 1)
    XCTAssertEqual(request.cancelCount, 0)
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
