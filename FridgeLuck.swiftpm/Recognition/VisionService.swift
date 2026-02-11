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

  private struct ResolvedClassification {
    let ingredientId: Int64
    let confidence: Float
    let originalLabel: String
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
    var resolvedClassifications: [ResolvedClassification] = []

    // Process classifications: filter to food-related labels and keep alternatives context.
    for obs in classifications where obs.confidence > 0.1 {
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
          originalLabel: originalLabel
        )
      )
    }

    // Keep one best detection per ingredient from classification.
    var bestByIngredient: [Int64: ResolvedClassification] = [:]
    for candidate in resolvedClassifications {
      guard
        let existing = bestByIngredient[candidate.ingredientId]
      else {
        bestByIngredient[candidate.ingredientId] = candidate
        continue
      }
      if candidate.confidence > existing.confidence {
        bestByIngredient[candidate.ingredientId] = candidate
      }
    }

    let topResolved = resolvedClassifications.sorted { $0.confidence > $1.confidence }

    // Build classification detections with top alternatives + learned suggestion.
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
          alternatives: alternatives
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
            originalVisionLabel: text,
            alternatives: []
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
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["en-US"]
      request.customWords = [
        "Calories", "Serving Size", "Servings per container", "kcal",
      ]
      request.minimumTextHeight = 0.01
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
