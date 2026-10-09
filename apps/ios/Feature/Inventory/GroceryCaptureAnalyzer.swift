import Foundation
import UIKit
import os

import FLFeatureLogic

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "GroceryCaptureAnalyzer")

/// Runs the recognition pipeline for one captured grocery photo and returns review drafts
/// mapped into the app's pending items. The vision passes and identity glue are injected so
/// tests can stub them; production wires the app's `VisionService` and ingredient catalog.
struct GroceryCaptureAnalyzer {
  enum Mode: Sendable {
    case photo
    case receipt
  }

  /// The recognition passes, injected so tests can stub them.
  struct Passes {
    let photo: (CGImage) async throws -> (
      detections: [GroceryDetectionInput], ocrText: [String]
    )
    let receipt: (CGImage) async throws -> [String]
  }

  /// Identity and catalog glue, injected so tests can stub it.
  struct Glue {
    /// Resolves receipt-line text to an ingredient with its identity confidence.
    let resolveLine: (String) -> (id: Int64, confidence: Double)?
    /// Correction candidates for line text, for the identity menu.
    let alternativesFor: (String) -> [GroceryAlternative]
    /// Display name for a resolved ingredient.
    let displayName: (Int64) -> String
    /// Known unit mass for an ingredient, or nil when nothing is known.
    let estimateUnitGrams: (Int64) -> Double?
    /// Known unit mass from a free-text name, or nil when nothing is known.
    let estimateGramsForName: (String) -> Double?
    /// Storage-location inference for a resolved ingredient.
    let inferLocation: (Int64) -> InventoryStorageLocation
  }

  let passes: Passes
  let glue: Glue

  init(passes: Passes, glue: Glue) {
    self.passes = passes
    self.glue = glue
  }

  func analyze(image: CGImage, mode: Mode) async throws -> [GroceryPendingItem] {
    let startedAt = Date()
    let drafts: [GroceryDraftItem]

    switch mode {
    case .photo:
      let (detections, ocrText) = try await passes.photo(image)
      logger.info("Photo pass returned detections=\(detections.count) ocr=\(ocrText.count)")
      drafts = GroceryIntakeNormalizer.draftItems(
        fromDetections: detections,
        ocrText: ocrText,
        estimateGramsForName: glue.estimateGramsForName,
        inferLocation: { id in
          GroceryStorageLocation(rawValue: glue.inferLocation(id).rawValue) ?? .unknown
        }
      )
    case .receipt:
      let lines = try await passes.receipt(image)
      logger.info("Receipt pass returned lines=\(lines.count)")
      drafts = GroceryIntakeNormalizer.draftItems(
        fromReceiptLines: lines,
        resolve: glue.resolveLine,
        alternativesFor: glue.alternativesFor,
        estimateUnitGrams: glue.estimateUnitGrams,
        inferLocation: { id in
          GroceryStorageLocation(rawValue: glue.inferLocation(id).rawValue) ?? .unknown
        }
      )
    }

    let items = drafts.map(pendingItem)
    logger.info(
      "Grocery analysis completed in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms: drafts=\(drafts.count) resolvedAmounts=\(drafts.filter { $0.amountGrams != nil }.count)"
    )
    return items
  }

  /// Recognition auto-accepts an identity only at the router's confirmed threshold; below
  /// that the review asks rather than assumes.
  private func pendingItem(from draft: GroceryDraftItem) -> GroceryPendingItem {
    let autoAcceptThreshold =
      draft.source == .ocr
      ? Double(ConfidenceRouter.Thresholds.ocrExactAuto)
      : Double(ConfidenceRouter.Thresholds.visionAuto)

    return GroceryPendingItem(
      ingredientId: draft.ingredientId,
      ingredientName: draft.ingredientId.map(glue.displayName) ?? draft.title,
      quantityGrams: draft.amountGrams,
      storageLocation: InventoryStorageLocation(rawValue: draft.location.rawValue) ?? .unknown,
      confidenceScore: draft.confidence,
      source: InventoryLotSource(rawValue: draft.source.rawValue) ?? .scan,
      isConfirmed: draft.ingredientId != nil && draft.confidence >= autoAcceptThreshold,
      quantityProvenance: draft.provenance.map { QuantityProvenance(rawValue: $0.rawValue)! },
      countEvidence: draft.countEvidence,
      evidenceSummary: draft.evidenceSummary,
      rawDescription: draft.rawDescription,
      alternatives: draft.alternatives
    )
  }
}
