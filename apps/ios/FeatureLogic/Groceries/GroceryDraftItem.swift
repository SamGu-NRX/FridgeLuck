import Foundation

/// Mirror of the app's storage locations, raw-value compatible. This module stays
/// Foundation-only, so the app glue maps to `InventoryStorageLocation` by raw value.
public enum GroceryStorageLocation: String, Sendable, Equatable {
  case fridge
  case pantry
  case freezer
  case unknown
}

/// An ingredient the user could replace a draft's identity with (correction menu entry).
public struct GroceryAlternative: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let name: String

  public init(id: Int64, name: String) {
    self.id = id
    self.name = name
  }
}

/// Where a draft came from. Raw-value compatible with the app's lot sources.
public enum GroceryDraftSource: String, Sendable, Equatable {
  case vision
  case ocr
  case manual
}

/// One food the user confirmed (or is about to) in the grocery review, before persistence.
/// Amounts stay `nil` when the source carried no weight — review resolves them; nothing here
/// invents grams from a price or a bare count without a known unit mass.
public struct GroceryDraftItem: Identifiable, Sendable, Equatable {
  public let id: UUID
  /// Resolved ingredient, or `nil` while identity needs the user's choice.
  public var ingredientId: Int64?
  /// What the review shows for this line: the resolved name or the raw OCR text.
  public var title: String
  /// Identity confidence from recognition; 1.0 for user-entered items.
  public var confidence: Double
  /// Confirmed amount in grams; `nil` needs review before the session can commit.
  public var amountGrams: Double?
  /// Count evidence read off the line ("2 @", "x2"), kept for the summary.
  public var countEvidence: Int?
  public var provenance: GroceryAmountProvenance?
  /// The raw line or detection label this draft came from.
  public var rawDescription: String
  /// Short evidence shown in review: "0.94 lb", "2 @ $3.99", "NET WT 454 G".
  public var evidenceSummary: String?
  public var location: GroceryStorageLocation
  public var source: GroceryDraftSource
  public var alternatives: [GroceryAlternative]

  /// A session can commit only fully resolved items: identity picked, positive amount set.
  public var isResolvedForCommit: Bool {
    ingredientId != nil && amountGrams != nil && (amountGrams ?? 0) > 0
  }

  public init(
    id: UUID = UUID(),
    ingredientId: Int64?,
    title: String,
    confidence: Double,
    amountGrams: Double?,
    countEvidence: Int? = nil,
    provenance: GroceryAmountProvenance?,
    rawDescription: String,
    evidenceSummary: String? = nil,
    location: GroceryStorageLocation,
    source: GroceryDraftSource,
    alternatives: [GroceryAlternative] = []
  ) {
    self.id = id
    self.ingredientId = ingredientId
    self.title = title
    self.confidence = confidence
    self.amountGrams = amountGrams
    self.countEvidence = countEvidence
    self.provenance = provenance
    self.rawDescription = rawDescription
    self.evidenceSummary = evidenceSummary
    self.location = location
    self.source = source
    self.alternatives = alternatives
  }
}
