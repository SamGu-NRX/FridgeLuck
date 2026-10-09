import Foundation
import UIKit
import Vision
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "VisionService")

/// Multi-pass image recognition pipeline.
/// Pass 1: VNClassifyImageRequest (food labels + confidence)
/// Pass 2: VNRecognizeTextRequest (OCR for packaging text)
/// Results are normalized through LearningService and IngredientLexicon.
final class VisionService: Sendable {
  private let learningService: LearningService
  private let ingredientResolver: IngredientCatalogResolving
  private let classificationRequest: @Sendable (CGImage) async throws -> [ClassificationResult]
  private let textRequest: @Sendable (CGImage) async throws -> [RecognizedTextResult]

  enum VisionServiceError: LocalizedError {
    case pipelineFailed(
      classificationError: Error?, ocrError: Error?,
      passErrors: [String], requestFailures: [ScanRequestFailure])

    var passErrors: [String] {
      switch self {
      case .pipelineFailed(_, _, let passErrors, _): return passErrors
      }
    }

    var requestFailures: [ScanRequestFailure] {
      switch self {
      case .pipelineFailed(_, _, _, let requestFailures): return requestFailures
      }
    }

    var errorDescription: String? {
      "Image recognition failed. Please try another photo."
    }
  }

  struct ClassificationResult: Sendable {
    let identifier: String
    let confidence: Float
  }

  struct RecognizedTextResult: Sendable {
    let candidates: [String]
    let boundingBox: CGRect
  }

  struct ScanResult: Sendable {
    let detections: [Detection]
    let ocrText: [String]
    let diagnostics: ScanDiagnostics
    let provenance: ScanProvenance
  }

  private struct ResolvedClassification {
    let ingredientId: Int64
    let confidence: Float
    let originalLabel: String
    let cropID: String
    let captureIndex: Int
  }

  private typealias ResolvedOCR = IngredientOCRMatchAggregation.Match

  init(
    learningService: LearningService,
    ingredientResolver: IngredientCatalogResolving,
    classificationRequest: @escaping @Sendable (CGImage) async throws -> [ClassificationResult] = VisionService.classifyImage,
    textRequest: @escaping @Sendable (CGImage) async throws -> [RecognizedTextResult] = VisionService.recognizeText
  ) {
    self.learningService = learningService
    self.ingredientResolver = ingredientResolver
    self.classificationRequest = classificationRequest
    self.textRequest = textRequest
  }

  // MARK: - Public API

  /// Scan an image and return detected ingredients with confidence scores.
  func scan(image: CGImage) async throws -> ScanResult {
    logger.info("Starting single-image scan request.")
    return try await scan(
      inputs: [
        ScanInput(
          image: image,
          source: .camera,
          captureIndex: 0
        )
      ]
    )
  }

  /// Session API for multi-shot scan aggregation.
  func scan(inputs: [ScanInput]) async throws -> ScanResult {
    let startedAt = Date()
    logger.info("Starting scan session. captures=\(inputs.count, privacy: .public)")
    guard !inputs.isEmpty else {
      logger.debug("Scan session has no inputs; returning empty result.")
      return ScanResult(
        detections: [],
        ocrText: [],
        diagnostics: ScanDiagnostics(
          captureCount: 0,
          cropCount: 0,
          topRawLabels: [],
          ocrCandidates: [],
          bucketCounts: ScanBucketCounts(auto: 0, confirm: 0, possible: 0),
          passErrors: [],
          elapsedMs: 0
        ),
        provenance: .realScan
      )
    }

    var resolvedClassifications: [ResolvedClassification] = []
    var resolvedOCRMatches: [ResolvedOCR] = []
    var rawLabels: [String] = []
    var ocrStrings: [String] = []
    var passErrors: [String] = []
    var requestFailures: [ScanRequestFailure] = []
    var cropCount = 0
    var firstClassificationError: Error?
    var firstOCRError: Error?
    var hadClassificationSuccess = false
    var hadOCRSuccess = false

    for input in inputs {
      let crops = ScanImagePreprocessor.deterministicCrops(for: input.image)
      logger.debug(
        "Capture index=\(input.captureIndex, privacy: .public), source=\(input.source.rawValue, privacy: .public), crops=\(crops.count, privacy: .public)"
      )
      for crop in crops {
        cropCount += 1

        async let classPass = classificationRequest(crop.image)
        async let ocrPass = textRequest(crop.image)

        let classifications: [ClassificationResult]
        let textObservations: [RecognizedTextResult]

        var classificationError: Error?
        var ocrError: Error?
        do {
          classifications = try await classPass
          hadClassificationSuccess = true
          logger.debug(
            "Classification pass succeeded. capture=\(input.captureIndex, privacy: .public), crop=\(crop.id, privacy: .public), labels=\(classifications.count, privacy: .public)"
          )
        } catch {
          classifications = []
          classificationError = error
          if firstClassificationError == nil { firstClassificationError = error }
          logger.error(
            "Classification pass failed. capture=\(input.captureIndex, privacy: .public), crop=\(crop.id, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
          )
        }

        do {
          textObservations = try await ocrPass
          hadOCRSuccess = true
          logger.debug(
            "OCR pass succeeded. capture=\(input.captureIndex, privacy: .public), crop=\(crop.id, privacy: .public), observations=\(textObservations.count, privacy: .public)"
          )
        } catch {
          textObservations = []
          ocrError = error
          if firstOCRError == nil { firstOCRError = error }
          logger.error(
            "OCR pass failed. capture=\(input.captureIndex, privacy: .public), crop=\(crop.id, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
          )
        }

        requestFailures.append(contentsOf: ScanDiagnostics.requestFailures(
          captureIndex: input.captureIndex,
          cropID: crop.id,
          classificationError: classificationError,
          ocrError: ocrError
        ))
        passErrors.append(contentsOf: ScanDiagnostics.cropPassErrors(
          captureIndex: input.captureIndex, cropID: crop.id,
          classificationError: classificationError, ocrError: ocrError
        ))

        for obs in classifications where obs.confidence > 0.1 {
          rawLabels.append(obs.identifier)

          let originalLabel = obs.identifier
          guard
            let ingredientId = IngredientIdentityResolution.resolveLabel(
              originalLabel,
              userCorrection: learningService.correctedIngredientId(for:),
              curated: IngredientLexicon.resolve,
              catalog: ingredientResolver.resolve
            )
          else { continue }
          resolvedClassifications.append(
            ResolvedClassification(
              ingredientId: ingredientId,
              confidence: obs.confidence,
              originalLabel: originalLabel,
              cropID: crop.id,
              captureIndex: input.captureIndex
            )
          )
        }

        let ocrLines = textObservations.compactMap { obs -> IngredientOCRLineJoining.Line? in
          guard let topText = obs.candidates.first else { return nil }
          return .init(text: topText, boundingBox: obs.boundingBox)
        }
        ocrStrings.append(contentsOf: ocrLines.map(\.text))
        for line in IngredientOCRLineJoining.joinAdjacent(ocrLines) {
          let topText = line.text
          if let matched = IngredientLexicon.resolveFromTextDetailed(topText) {
            let confidence: Float =
              matched.kind == .exact
              ? ConfidenceRouter.Thresholds.ocrExactAuto
              : ConfidenceRouter.Thresholds.ocrExactConfirmMin
            resolvedOCRMatches.append(
              ResolvedOCR(
                ingredientId: matched.ingredientId,
                confidence: confidence,
                originalText: topText,
                matchedToken: matched.matchedToken,
                kind: matched.kind,
                boundingBox: line.boundingBox,
                cropID: crop.id,
                captureIndex: input.captureIndex,
                isCatalogFallback: false,
                joinedParts: line.joinedParts
              )
            )
          } else if let resolvedId = IngredientIdentityResolution.resolveTextFromCatalog(
            topText,
            catalogName: { ingredientResolver.resolve($0, matching: .allowPrefix) },
            catalogTokens: ingredientResolver.resolveFromText
          ) {
            resolvedOCRMatches.append(
              ResolvedOCR(
                ingredientId: resolvedId,
                confidence: ConfidenceRouter.Thresholds.ocrFuzzyConfirmMin,
                originalText: topText,
                matchedToken: topText,
                kind: .fuzzy,
                boundingBox: line.boundingBox,
                cropID: crop.id,
                captureIndex: input.captureIndex,
                isCatalogFallback: true,
                joinedParts: []
              )
            )
          }
        }
      }
    }

    var detections: [Detection] = []

    var bestByIngredient: [Int64: ResolvedClassification] = [:]
    for candidate in resolvedClassifications {
      guard let existing = bestByIngredient[candidate.ingredientId] else {
        bestByIngredient[candidate.ingredientId] = candidate
        continue
      }
      if candidate.confidence > existing.confidence {
        bestByIngredient[candidate.ingredientId] = candidate
      }
    }

    let topResolved = resolvedClassifications.sorted { $0.confidence > $1.confidence }

    for best in bestByIngredient.values {
      var alternativeIds: [Int64] = []
      if let suggested = learningService.suggestedCorrection(for: best.originalLabel),
        suggested != best.ingredientId
      {
        alternativeIds.append(suggested)
      }

      for candidate in topResolved where candidate.ingredientId != best.ingredientId {
        if !alternativeIds.contains(candidate.ingredientId) {
          alternativeIds.append(candidate.ingredientId)
        }
        if alternativeIds.count >= 3 { break }
      }

      let alternatives = alternativeIds.map {
        DetectionAlternative(
          ingredientId: $0,
          label: displayName(for: $0),
          confidence: nil
        )
      }

      detections.append(
        Detection(
          ingredientId: best.ingredientId,
          label: displayName(for: best.ingredientId),
          confidence: best.confidence,
          source: .vision,
          originalVisionLabel: best.originalLabel,
          alternatives: alternatives,
          normalizedBoundingBox: nil,
          evidenceTokens: [best.originalLabel],
          cropID: best.cropID,
          captureIndex: best.captureIndex,
          ocrMatchKind: nil
        ))
    }

    for ocr in IngredientOCRMatchAggregation.suppressJoinedParts(resolvedOCRMatches) {
      detections.append(
        Detection(
          ingredientId: ocr.ingredientId,
          label: displayName(for: ocr.ingredientId),
          confidence: ocr.confidence,
          source: .ocr,
          originalVisionLabel: ocr.originalText,
          alternatives: [],
          normalizedBoundingBox: ocr.boundingBox,
          evidenceTokens: [ocr.matchedToken],
          cropID: ocr.cropID,
          captureIndex: ocr.captureIndex,
          ocrMatchKind: ocr.kind
        ))
    }

    var bestDetectionByIngredient: [Int64: Detection] = [:]
    for candidate in detections {
      guard let existing = bestDetectionByIngredient[candidate.ingredientId] else {
        bestDetectionByIngredient[candidate.ingredientId] = candidate
        continue
      }

      let keepCandidate: Bool
      if candidate.confidence == existing.confidence {
        keepCandidate = sourcePriority(candidate) > sourcePriority(existing)
      } else {
        keepCandidate = candidate.confidence > existing.confidence
      }

      if keepCandidate {
        bestDetectionByIngredient[candidate.ingredientId] = candidate
      }
    }

    let deduplicated = bestDetectionByIngredient.values.sorted { $0.confidence > $1.confidence }

    if deduplicated.isEmpty, !hadClassificationSuccess, !hadOCRSuccess {
      logger.error(
        "Scan session failed: no successful passes. classError=\(firstClassificationError?.localizedDescription ?? "nil", privacy: .public), ocrError=\(firstOCRError?.localizedDescription ?? "nil", privacy: .public)"
      )
      throw VisionServiceError.pipelineFailed(
        classificationError: firstClassificationError,
        ocrError: firstOCRError,
        passErrors: passErrors,
        requestFailures: requestFailures
      )
    }

    let categorized = ConfidenceRouter.categorize(deduplicated)
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    let diagnostics = ScanDiagnostics(
      captureCount: inputs.count,
      cropCount: cropCount,
      topRawLabels: Array(Set(rawLabels)).sorted().prefix(24).map { $0 },
      ocrCandidates: Array(Set(ocrStrings)).sorted().prefix(24).map { $0 },
      bucketCounts: ScanBucketCounts(
        auto: categorized.confirmed.count,
        confirm: categorized.needsConfirmation.count,
        possible: categorized.possible.count
      ),
      passErrors: passErrors,
      elapsedMs: elapsedMs,
      requestFailures: requestFailures
    )

    logger.info(
      "Scan session completed. elapsedMs=\(elapsedMs, privacy: .public), detections=\(deduplicated.count, privacy: .public), auto=\(categorized.confirmed.count, privacy: .public), confirm=\(categorized.needsConfirmation.count, privacy: .public), possible=\(categorized.possible.count, privacy: .public), cropCount=\(cropCount, privacy: .public)"
    )
    if !passErrors.isEmpty {
      logger.debug("Scan pass errors count=\(passErrors.count, privacy: .public)")
    }

    return ScanResult(
      detections: deduplicated,
      ocrText: ocrStrings,
      diagnostics: diagnostics,
      provenance: .realScan
    )
  }

  // MARK: - Vision Passes (synchronous, run on detached tasks)

  /// Classify the image using VNClassifyImageRequest.
  /// Runs synchronously on a background thread — no continuation needed.
  private static func classifyImage(_ image: CGImage) async throws -> [ClassificationResult] {
    try await Task.detached(priority: .userInitiated) {
      let request = VNClassifyImageRequest()
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])

      let observations = request.results ?? []
      return observations.map { obs in
        ClassificationResult(identifier: obs.identifier, confidence: obs.confidence)
      }
    }.value
  }

  /// Recognize text in the image using VNRecognizeTextRequest.
  /// Runs synchronously on a background thread — no continuation needed.
  private static func recognizeText(_ image: CGImage) async throws -> [RecognizedTextResult] {
    try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["en-US"]
      request.customWords = [
        "Calories", "Serving Size", "Servings per container", "kcal",
      ]
      request.minimumTextHeight = 0.01
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])

      let observations = request.results ?? []
      return observations.map { obs in
        let strings = obs.topCandidates(3).map { $0.string }
        return RecognizedTextResult(candidates: strings, boundingBox: obs.boundingBox)
      }
    }.value
  }

  private func sourcePriority(_ detection: Detection) -> Int {
    switch detection.source {
    case .manual: return 3
    case .ocr:
      switch detection.ocrMatchKind ?? .exact {
      case .exact: return 2
      case .fuzzy: return 1
      }
    case .vision:
      return 0
    }
  }

  private func displayName(for ingredientId: Int64) -> String {
    ingredientResolver.displayName(for: ingredientId)
      ?? IngredientLexicon.displayName(for: ingredientId)
  }
}
