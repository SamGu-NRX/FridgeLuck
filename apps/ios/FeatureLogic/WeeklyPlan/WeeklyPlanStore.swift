import Foundation

// MARK: - Violation display text (stable wording)

public enum WeeklyPlanViolationText {
  /// Stable, user-facing wording. The associated values are IDs the app layer
  /// resolves to names; the structure of the sentence is fixed here.
  public static func describe(_ violation: WeeklyPlanViolation) -> String {
    switch violation {
    case .noEligibleRecipe(let slotId):
      return "No recipe can fill slot \(slotId) under the current constraints."
    case .excludedIngredientRequired(let recipeId, let ingredientId):
      return "Recipe \(recipeId) requires ingredient \(ingredientId), which is excluded. Exclusions are never waived."
    case .dietClassMismatch(let recipeId):
      return "Recipe \(recipeId) does not match the selected diet."
    case .cookTimeExceeded(let recipeId, let slotId):
      return "Recipe \(recipeId) exceeds the time limit for slot \(slotId)."
    case .insufficientStock(let ingredientId, let shortfallGrams):
      return "Short by \(Int(shortfallGrams.rounded())) g of ingredient \(ingredientId)."
    case .unknownAmountCannotCover(let ingredientId):
      return "Ingredient \(ingredientId) has no confirmed amount on hand, so the plan cannot count it."
    }
  }
}

// MARK: - Plan store record

/// The persisted shape of one weekly plan. Deliberately self-contained: no
/// database rows, no migration registrar, no repository queries — a single
/// JSON file owned by this store. Selections persist here and nowhere else;
/// they never reserve or consume stock and there is no purchase integration.
public struct WeeklyPlanRecord: Codable, Sendable, Equatable {
  /// Fingerprint of the inputs the plan was computed from (staleness key).
  public var fingerprint: String
  public var isFeasible: Bool
  public var assignments: [WeeklyPlanSlotAssignment]
  public var shortages: [WeeklyPlanShortage]
  public var violations: [String]
  public var score: Double
  /// Candidate recipe ids offered at planning time, for the edit picker.
  public var candidateRecipeIds: [Int64]
  public var slots: [WeeklyPlanSlot]

  public init(
    fingerprint: String, isFeasible: Bool, assignments: [WeeklyPlanSlotAssignment],
    shortages: [WeeklyPlanShortage], violations: [String], score: Double,
    candidateRecipeIds: [Int64], slots: [WeeklyPlanSlot]
  ) {
    self.fingerprint = fingerprint
    self.isFeasible = isFeasible
    self.assignments = assignments
    self.shortages = shortages
    self.violations = violations
    self.score = score
    self.candidateRecipeIds = candidateRecipeIds
    self.slots = slots
  }

  public init(result: WeeklyPlanResult, candidateRecipeIds: [Int64], slots: [WeeklyPlanSlot]) {
    var violationTexts: [String] = []
    if case .infeasible(let violations) = result.verdict {
      violationTexts = violations.map(WeeklyPlanViolationText.describe)
    }
    self.init(
      fingerprint: result.inputFingerprint,
      isFeasible: result.verdict == WeeklyPlanVerdict.feasible,
      assignments: result.assignments,
      shortages: result.shortages,
      violations: violationTexts,
      score: result.score,
      candidateRecipeIds: candidateRecipeIds,
      slots: slots)
  }
}

/// The stored plan plus its lifecycle. Exactly one record exists: the current
/// draft or the accepted plan. Removing it is how a week resets.
public struct WeeklyPlanStoreEntry: Codable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable {
    case draft
    case accepted
  }

  public var phase: Phase
  public var plan: WeeklyPlanRecord
  public var createdAt: Date
  public var acceptedAt: Date?
  /// Set when the user edited an accepted plan; edits always demote the plan
  /// to a draft — acceptance is never silently carried over.
  public var lastEditedAt: Date?

  public init(
    phase: Phase, plan: WeeklyPlanRecord, createdAt: Date, acceptedAt: Date? = nil,
    lastEditedAt: Date? = nil
  ) {
    self.phase = phase
    self.plan = plan
    self.createdAt = createdAt
    self.acceptedAt = acceptedAt
    self.lastEditedAt = lastEditedAt
  }
}

// MARK: - Store

/// The separate small plan store: one JSON file in a directory the app chooses
/// (Application Support). Atomic replace on write; deterministic serialization
/// (sorted keys) so files are diffable and tests are exact.
public final class WeeklyPlanStore: @unchecked Sendable {

  public static let defaultFileName = "weekly-plan-store.json"

  private let fileURL: URL
  private let lock = NSLock()

  /// - Parameter directory: existing or creatable directory for the store.
  public init(directory: URL, fileName: String = WeeklyPlanStore.defaultFileName) {
    self.fileURL = directory.appendingPathComponent(fileName)
  }

  /// Loads the current entry, or nil when no plan is stored. A corrupt file
  /// reads as "no plan" — planning is cheap and always recomputable, and a
  /// broken store must never wedge the app.
  public func load() -> WeeklyPlanStoreEntry? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(WeeklyPlanStoreEntry.self, from: data)
  }

  public func save(_ entry: WeeklyPlanStoreEntry) throws {
    lock.lock()
    defer { lock.unlock() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
    try data.write(to: temporary, options: .atomic)
    // Replace so readers never observe a half-written file.
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    try FileManager.default.moveItem(at: temporary, to: fileURL)
  }

  public func remove() throws {
    lock.lock()
    defer { lock.unlock() }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}
