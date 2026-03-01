import Foundation
import UIKit
import Vision

/// Multi-pass image recognition pipeline.
/// Pass 1: VNClassifyImageRequest (food labels + confidence)
/// Pass 2: VNRecognizeTextRequest (OCR for packaging text)
/// Results are normalized through LearningService and IngredientLexicon.
final class VisionService: Sendable {
  private let learningService: LearningService

  enum VisionServiceError: LocalizedError {
    case pipelineFailed(classificationError: Error?, ocrError: Error?)

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

  private struct ResolvedOCR {
    let ingredientId: Int64
    let confidence: Float
    let originalText: String
    let matchedToken: String
    let kind: OCRMatchKind
    let boundingBox: CGRect
    let cropID: String
    let captureIndex: Int
  }

  init(learningService: LearningService) {
    self.learningService = learningService
  }

  // MARK: - Public API

  /// Scan an image and return detected ingredients with confidence scores.
  func scan(image: CGImage) async throws -> ScanResult {
    try await scan(
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
    guard !inputs.isEmpty else {
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
    var cropCount = 0
    var firstClassificationError: Error?
    var firstOCRError: Error?
    var hadClassificationSuccess = false
    var hadOCRSuccess = false

    for input in inputs {
      let crops = ScanImagePreprocessor.deterministicCrops(for: input.image)
      for crop in crops {
        cropCount += 1

        async let classPass = classifyImage(crop.image)
        async let ocrPass = recognizeText(crop.image)

        let classifications: [ClassificationResult]
        let textObservations: [RecognizedTextResult]

        var classificationError: Error?
        var ocrError: Error?
        do {
          classifications = try await classPass
          hadClassificationSuccess = true
        } catch {
          classifications = []
          classificationError = error
          if firstClassificationError == nil { firstClassificationError = error }
        }

        do {
          textObservations = try await ocrPass
          hadOCRSuccess = true
        } catch {
          textObservations = []
          ocrError = error
          if firstOCRError == nil { firstOCRError = error }
        }

        if let classificationError, let ocrError {
          passErrors.append(
            "capture=\(input.captureIndex),crop=\(crop.id):class=\(String(describing: classificationError)),ocr=\(String(describing: ocrError))"
          )
        }

        for obs in classifications where obs.confidence > 0.1 {
          rawLabels.append(obs.identifier)

          let originalLabel = obs.identifier
          var resolvedId = learningService.correctedIngredientId(for: originalLabel)
          if resolvedId == nil {
            resolvedId = IngredientLexicon.resolve(originalLabel)
          }
          guard let ingredientId = resolvedId else { continue }
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

        for obs in textObservations {
          guard let topText = obs.candidates.first else { continue }
          ocrStrings.append(topText)
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
                boundingBox: obs.boundingBox,
                cropID: crop.id,
                captureIndex: input.captureIndex
              )
            )
          }
        }
      }
    }

    var detections: [Detection] = []

    // Keep one best classification per ingredient.
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
          label: IngredientLexicon.displayName(for: $0),
          confidence: nil
        )
      }

      detections.append(
        Detection(
          ingredientId: best.ingredientId,
          label: IngredientLexicon.displayName(for: best.ingredientId),
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

    for ocr in resolvedOCRMatches {
      detections.append(
        Detection(
          ingredientId: ocr.ingredientId,
          label: IngredientLexicon.displayName(for: ocr.ingredientId),
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

    // Deduplicate by ingredientId, favoring stronger confidence and then stronger source quality.
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
      throw VisionServiceError.pipelineFailed(
        classificationError: firstClassificationError,
        ocrError: firstOCRError
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
      elapsedMs: elapsedMs
    )

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
  private func classifyImage(_ image: CGImage) async throws -> [ClassificationResult] {
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
  private func recognizeText(_ image: CGImage) async throws -> [RecognizedTextResult] {
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
}
