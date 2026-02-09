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
  }

  struct ScanResult: Sendable {
    let detections: [Detection]
    let ocrText: [String]
  }

  init(learningService: LearningService) {
    self.learningService = learningService
  }

  // MARK: - Public API

  /// Scan an image and return detected ingredients with confidence scores.
  func scan(image: CGImage) async throws -> ScanResult {
    // Run both Vision passes concurrently on background threads.
    // Uses Task.detached to avoid blocking the main actor and to avoid
    // the fragile withCheckedThrowingContinuation pattern that causes
    // double-resume crashes with Vision's completion handlers.
    async let classResults = classifyImage(image)
    async let ocrResults = recognizeText(image)

    // Classification can fail on simulator (no ML backend).
    // Treat classification failure as empty results — OCR + manual add still work.
    let classifications: [ClassificationResult]
    var classificationError: Error?
    do {
      classifications = try await classResults
    } catch {
      classifications = []
      classificationError = error
    }

    let textObservations: [RecognizedTextResult]
    var ocrError: Error?
    do {
      textObservations = try await ocrResults
    } catch {
      textObservations = []
      ocrError = error
    }

    var detections: [Detection] = []

    // Process classifications: filter to food-related labels
    for obs in classifications where obs.confidence > 0.1 {
      let originalLabel = obs.identifier

      // 1. Check user corrections (highest priority — continual learning)
      var resolvedId: Int64?
      if let correctedId = learningService.correctedIngredientId(for: originalLabel) {
        resolvedId = correctedId
      }

      // 2. Fall back to lexicon normalization
      if resolvedId == nil {
        resolvedId = IngredientLexicon.resolve(originalLabel)
      }

      guard let ingredientId = resolvedId else { continue }

      detections.append(
        Detection(
          ingredientId: ingredientId,
          label: IngredientLexicon.displayName(for: ingredientId),
          confidence: obs.confidence,
          source: .vision,
          originalVisionLabel: originalLabel
        ))
    }

    // Process OCR text: look for ingredient names
    let ocrStrings: [String] = textObservations.compactMap { $0.candidates.first }

    for text in ocrStrings {
      if let ingredientId = IngredientLexicon.resolveFromText(text) {
        guard !detections.contains(where: { $0.ingredientId == ingredientId }) else {
          continue
        }

        detections.append(
          Detection(
            ingredientId: ingredientId,
            label: IngredientLexicon.displayName(for: ingredientId),
            confidence: 0.85,
            source: .ocr,
            originalVisionLabel: text
          ))
      }
    }

    // Deduplicate by ingredientId (keep highest confidence)
    let deduplicated = Dictionary(
      grouping: detections,
      by: \.ingredientId
    ).values.compactMap { group in
      group.max(by: { $0.confidence < $1.confidence })
    }.sorted { $0.confidence > $1.confidence }

    // If both Vision passes errored, surface a real failure instead of silently
    // degrading to an empty result set.
    if deduplicated.isEmpty, classificationError != nil, ocrError != nil {
      throw VisionServiceError.pipelineFailed(
        classificationError: classificationError,
        ocrError: ocrError
      )
    }

    return ScanResult(detections: deduplicated, ocrText: ocrStrings)
  }

  // MARK: - Vision Passes (synchronous, run on detached tasks)

  /// Classify the image using VNClassifyImageRequest.
  /// Runs synchronously on a background thread — no continuation needed.
  private func classifyImage(_ image: CGImage) async throws -> [ClassificationResult] {
    try await Task.detached(priority: .userInitiated) {
      let request = VNClassifyImageRequest()
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])

      let observations = (request.results as? [VNClassificationObservation]) ?? []
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
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])

      let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
      return observations.map { obs in
        let strings = obs.topCandidates(3).map { $0.string }
        return RecognizedTextResult(candidates: strings)
      }
    }.value
  }
}
