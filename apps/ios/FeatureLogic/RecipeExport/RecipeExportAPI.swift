import Foundation

/// Pinned public seam for the recipe amount-export flow. The app UI codes against
/// exactly these names; render/prepare/filename/drift bodies live in sibling files.
///
/// The export is an amount list only: photo paths, journal notes, health summaries,
/// ratings, database IDs, cooking instructions, and OCR text never reach the output.

public enum RecipeExportQuantityPresentation: String, CaseIterable, Sendable {
  case metricGrams
  case imperialOunces
}

/// Fields the export must exclude. Kept as raw strings so the caller decides what
/// was read from the recipe record; the logic only guarantees they never render.
public struct RecipeExportExcludedFields: Sendable, Equatable {
  public var photoPath: String
  public var journalNotes: String
  public var healthSummary: String
  public var rating: String
  public var databaseID: String
  public var instructions: String
  public var ocrText: String

  public init(
    photoPath: String = "",
    journalNotes: String = "",
    healthSummary: String = "",
    rating: String = "",
    databaseID: String = "",
    instructions: String = "",
    ocrText: String = ""
  ) {
    self.photoPath = photoPath
    self.journalNotes = journalNotes
    self.healthSummary = healthSummary
    self.rating = rating
    self.databaseID = databaseID
    self.instructions = instructions
    self.ocrText = ocrText
  }
}

public struct RecipeExportRowIntake: Sendable, Equatable {
  public var name: String
  public var isRequired: Bool
  public var amount: Double?
  public var unit: String?
  public var replacementNote: String?
  public var substitutedName: String?
  public var substitutionRatio: Double?

  public init(
    name: String,
    isRequired: Bool,
    amount: Double? = nil,
    unit: String? = nil,
    replacementNote: String? = nil,
    substitutedName: String? = nil,
    substitutionRatio: Double? = nil
  ) {
    self.name = name
    self.isRequired = isRequired
    self.amount = amount
    self.unit = unit
    self.replacementNote = replacementNote
    self.substitutedName = substitutedName
    self.substitutionRatio = substitutionRatio
  }
}

public struct RecipeExportIntake: Sendable, Equatable {
  public var recipeName: String
  public var originalServings: Int?
  public var sourceURL: URL?
  public var rows: [RecipeExportRowIntake]
  public var excluded: RecipeExportExcludedFields

  public init(
    recipeName: String,
    originalServings: Int? = nil,
    sourceURL: URL? = nil,
    rows: [RecipeExportRowIntake] = [],
    excluded: RecipeExportExcludedFields = RecipeExportExcludedFields()
  ) {
    self.recipeName = recipeName
    self.originalServings = originalServings
    self.sourceURL = sourceURL
    self.rows = rows
    self.excluded = excluded
  }
}

public enum RecipeExportError: Error, Equatable, Sendable {
  case recipeReadFailed
  case recipeMissing
  case inconsistentRecipeRead(String)
  case invalidOriginalServings(Int?)
  case invalidExportServings(Double)
}

public struct RecipeExportPreparedRow: Sendable, Equatable {
  public let name: String
  public let isRequired: Bool
  public let replacementNote: String?
  public let substitutedName: String?
  public let substitutionRatio: Double?
  public let quantityText: String
}

public struct RecipeExportPrepared: Sendable, Equatable {
  public let recipeName: String
  public let originalServings: Int
  public let exportedServings: Double
  public let presentation: RecipeExportQuantityPresentation
  public let rows: [RecipeExportPreparedRow]
  public let sourceURL: URL?
  /// The intake as it was captured at preparation time; drift compares against this.
  public let capturedInputs: RecipeExportIntake

  public func renderedText() -> String {
    RecipeExportRendering.renderedText(of: self)
  }
}

public enum RecipeExportPreparer {
  public static func prepare(
    intake: RecipeExportIntake,
    exportedServings: Double,
    presentation: RecipeExportQuantityPresentation
  ) throws -> RecipeExportPrepared {
    try RecipeExportPreparation.prepare(
      intake: intake,
      exportedServings: exportedServings,
      presentation: presentation
    )
  }
}

public enum RecipeExportFilename {
  public static func defaultName(recipeName: String, exportedServings: Double) -> String {
    RecipeExportNaming.defaultName(recipeName: recipeName, exportedServings: exportedServings)
  }
}

public enum RecipeExportDrift {
  public static func isStale(liveIntake: RecipeExportIntake, prepared: RecipeExportPrepared) -> Bool {
    RecipeExportDriftEvaluation.isStale(liveIntake: liveIntake, prepared: prepared)
  }
}

public enum RecipeExportInteraction: Equatable, Sendable {
  case shareSheetClosed
  case shareCancelled
  case saveCompleted
  case saveCancelled
  case saveFailed(String)
}

public struct RecipeExportSession: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case idle
    case preparing
    case prepared
    case prepareFailed(RecipeExportError)
  }

  public private(set) var status: Status
  public private(set) var prepared: RecipeExportPrepared?
  public private(set) var lastInteraction: RecipeExportInteraction?
  public private(set) var generation: Int

  public init() {
    status = .idle
    prepared = nil
    lastInteraction = nil
    generation = 0
  }

  /// Starts a preparation attempt and returns its generation token. A previously
  /// prepared document stays in place until a valid completion replaces it.
  public mutating func beginPreparation() -> Int {
    generation += 1
    status = .preparing
    return generation
  }

  /// Applies a completed document only for the current generation; stale
  /// generations (from a superseded attempt) are silently discarded.
  public mutating func complete(_ doc: RecipeExportPrepared, generation: Int) {
    guard generation == self.generation else { return }
    prepared = doc
    status = .prepared
  }

  /// Records a failed attempt for the current generation. Any prior prepared
  /// document is preserved so the UI can keep showing it alongside the failure.
  public mutating func fail(_ error: RecipeExportError, generation: Int) {
    guard generation == self.generation else { return }
    status = .prepareFailed(error)
  }

  /// Cancels an in-flight preparation without recording a failure; content is
  /// preserved (falls back to .prepared when a document exists, .idle otherwise).
  public mutating func cancelPreparation() {
    guard status == .preparing else { return }
    status = prepared != nil ? .prepared : .idle
  }

  public mutating func noteInteraction(_ i: RecipeExportInteraction) {
    lastInteraction = i
  }
}
