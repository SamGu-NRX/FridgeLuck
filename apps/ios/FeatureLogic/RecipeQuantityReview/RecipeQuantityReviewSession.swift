import Foundation

/// The reads the amount review needs, as the review sees them.
///
/// Production adapters wrap the existing synchronous services (`RecipeRepository`,
/// `NutritionService`) — no network layer is invented here; the protocol exists so the
/// load sequence's cancellation discipline is testable offline.
public protocol RecipeQuantityReviewReading: Sendable {
  /// The fetched recipe's serving denominator, or nil when no recipe row exists.
  /// Throws when the read itself fails — missing and failed are different refusals.
  func fetchRecipeServings(id: Int64) throws -> Int?

  /// Fresh joined ingredient rows for the recipe, as the preview drawer's section reads them.
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow]

  /// Stored-energy nutrition for one ingredient at `grams`, from the existing service.
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition

  /// Calories per serving of the recipe as planned (original ingredients), or nil when
  /// that read is unavailable. This is the reference the recommendation scored, untouched.
  func referencePerServingCalories(recipeID: Int64) throws -> Double?
}

/// Loads one immutable review snapshot, checking cancellation between every read step so a
/// stale or cancelled load can never be committed as a snapshot.
///
/// The sequence validates a single recipe identity first and only then fetches the serving
/// denominator; empty, foreign, duplicated, or unusable rows refuse the load instead of
/// producing amounts.
public final class RecipeQuantityReviewSession: Sendable {
  private let read: any RecipeQuantityReviewReading

  public init(read: any RecipeQuantityReviewReading) {
    self.read = read
  }

  public func load(recipeID: Int64) async throws -> RecipeQuantityReviewSnapshot {
    // Fresh, authoritative rows — not the rows the caller happens to hold.
    let freshRows: [QuantityReviewJoinedRow]
    do {
      freshRows = try read.joinedRows(recipeID: recipeID)
    } catch {
      throw RecipeQuantityReviewFailure.readFailed(String(describing: error))
    }
    try Task.checkCancellation()
    try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: recipeID, rows: freshRows)

    // Identity is established; now the serving denominator may be fetched.
    let servings: Int?
    do {
      servings = try read.fetchRecipeServings(id: recipeID)
    } catch {
      throw RecipeQuantityReviewFailure.readFailed(String(describing: error))
    }
    try Task.checkCancellation()
    guard let recipeServings = servings else {
      throw RecipeQuantityReviewFailure.recipeNotFound(recipeID)
    }
    try RecipeQuantityReviewValidation.validateRecipeServings(recipeServings)

    // Nutrition reads are bounded: one per row, plus one per selected substitute.
    var snapshotRows: [RecipeQuantityReviewSnapshot.Row] = []
    snapshotRows.reserveCapacity(freshRows.count)
    for row in freshRows {
      try Task.checkCancellation()
      snapshotRows.append(try await self.row(from: row))
    }

    let reference: Double?
    do {
      reference = try read.referencePerServingCalories(recipeID: recipeID)
    } catch {
      reference = nil // The reference is a nicety; its read failure hides it, never fakes it.
    }
    try Task.checkCancellation()

    return RecipeQuantityReviewSnapshot(
      recipeID: recipeID,
      recipeServings: recipeServings,
      referenceCaloriesPerServing: reference,
      rows: snapshotRows)
  }

  private func row(from row: QuantityReviewJoinedRow) async throws -> RecipeQuantityReviewSnapshot.Row {
    let originalNutrition: QuantityReviewNutrition?
    do {
      originalNutrition = try read.nutrition(ingredientID: row.ingredientID, grams: row.quantityGrams)
    } catch {
      originalNutrition = nil // A failed read shows as unavailable, not as zero.
    }

    var replacementNutrition: QuantityReviewNutrition?
    if let substituteID = row.substituteID, let ratio = row.substituteRatio {
      try Task.checkCancellation()
      do {
        // The substitute's plan amount is the recipe grams through the existing ratio;
        // the nutrition read happens at exactly that amount, so the ratio is baked in once.
        replacementNutrition = try read.nutrition(
          ingredientID: substituteID, grams: row.quantityGrams * ratio)
      } catch {
        replacementNutrition = nil
      }
    }

    return RecipeQuantityReviewSnapshot.Row(
      ingredientID: row.ingredientID,
      originalName: row.displayName,
      replacementName: row.substituteName,
      isRequired: row.isRequired,
      baseOriginalGrams: row.quantityGrams,
      substituteRatio: row.substituteRatio,
      originalNutrition: originalNutrition,
      replacementNutrition: replacementNutrition)
  }
}

// MARK: - Validation

/// Identity and usability rules for the review's inputs.
public enum RecipeQuantityReviewValidation {
  /// Validates a single recipe identity across the joined rows before the serving
  /// denominator is fetched. Empty rows, rows bound to another recipe, duplicated
  /// ingredients, and unusable numbers are refusals — never silently repaired.
  public static func validateJoinedRows(
    recipeID: Int64?, rows: [QuantityReviewJoinedRow]
  ) throws {
    guard let recipeID else { throw RecipeQuantityReviewFailure.missingRecipeID }
    guard !rows.isEmpty else { throw RecipeQuantityReviewFailure.noIngredientRows }

    for row in rows where row.recipeID != recipeID {
      throw RecipeQuantityReviewFailure.inconsistentRows(
        "Row \(row.ingredientID) belongs to recipe \(row.recipeID), not \(recipeID)")
    }

    var seen = Set<Int64>()
    for row in rows {
      guard seen.insert(row.ingredientID).inserted else {
        throw RecipeQuantityReviewFailure.inconsistentRows(
          "Ingredient \(row.ingredientID) appears more than once")
      }
      guard row.quantityGrams.isFinite, row.quantityGrams >= 0 else {
        throw RecipeQuantityReviewFailure.inconsistentRows(
          "Ingredient \(row.ingredientID) has unusable grams \(row.quantityGrams)")
      }
      if let ratio = row.substituteRatio {
        guard ratio.isFinite, ratio > 0 else {
          throw RecipeQuantityReviewFailure.inconsistentRows(
            "Substitute ratio \(ratio) for ingredient \(row.ingredientID) is unusable")
        }
        if row.substituteName == nil {
          throw RecipeQuantityReviewFailure.inconsistentRows(
            "Ratio present without a substitute name for ingredient \(row.ingredientID)")
        }
      }
    }
  }

  /// The fetched recipe's serving count must be a usable denominator.
  public static func validateRecipeServings(_ servings: Int) throws {
    guard servings > 0 else {
      throw RecipeQuantityReviewFailure.invalidRecipeServings(servings)
    }
  }
}
