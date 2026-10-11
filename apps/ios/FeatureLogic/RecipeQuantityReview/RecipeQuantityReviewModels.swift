import Foundation

// MARK: - Joined row input

/// One recipe-ingredient row joined with its (optional) selected substitution, flattened to
/// primitives so the FLFeatureLogic framework needs no app model types.
///
/// The amount review validates these rows before it fetches anything else: the serving
/// denominator only means something once a single recipe identity is established.
public struct QuantityReviewJoinedRow: Sendable, Equatable {
  public let ingredientID: Int64
  public let recipeID: Int64
  public let isRequired: Bool
  /// Recipe grams for the original ingredient. For a substituted row this is still the
  /// original ingredient's recipe grams; the substitute's ratio converts it.
  public let quantityGrams: Double
  public let displayName: String
  /// Present only when a substitute is selected for this row.
  public let substituteID: Int64?
  public let substituteName: String?
  /// The existing substitution's gram-for-gram ratio (1.0 = same weight).
  public let substituteRatio: Double?

  public init(
    ingredientID: Int64,
    recipeID: Int64,
    isRequired: Bool,
    quantityGrams: Double,
    displayName: String,
    substituteID: Int64? = nil,
    substituteName: String? = nil,
    substituteRatio: Double? = nil
  ) {
    self.ingredientID = ingredientID
    self.recipeID = recipeID
    self.isRequired = isRequired
    self.quantityGrams = quantityGrams
    self.displayName = displayName
    self.substituteID = substituteID
    self.substituteName = substituteName
    self.substituteRatio = substituteRatio
  }
}

// MARK: - Nutrition

/// Nutrition facts for one ingredient amount, mapped from what `NutritionService` returned.
/// Calories are the stored energy value as-is — never reconstructed from macros.
public struct QuantityReviewNutrition: Sendable, Equatable {
  public let calories: Double
  public let protein: Double
  public let carbs: Double
  public let fat: Double

  public init(calories: Double, protein: Double, carbs: Double, fat: Double) {
    self.calories = calories
    self.protein = protein
    self.carbs = carbs
    self.fat = fat
  }
}

// MARK: - Snapshot

/// Immutable result of one completed read of a recipe's amount facts.
///
/// Everything is held at base quantities (the amounts the accepted plan logs); serving
/// scaling happens in the calculator, from these bases, exactly once per factor change.
public struct RecipeQuantityReviewSnapshot: Sendable, Equatable {
  public struct Row: Sendable, Equatable {
    public let ingredientID: Int64
    public let originalName: String
    /// The selected substitute's name, when one is selected for this row.
    public let replacementName: String?
    public let isRequired: Bool
    public let baseOriginalGrams: Double
    public let substituteRatio: Double?
    /// Stored-energy nutrition for the original at `baseOriginalGrams`.
    public let originalNutrition: QuantityReviewNutrition?
    /// Stored-energy nutrition for the substitute at `baseOriginalGrams × ratio`.
    public let replacementNutrition: QuantityReviewNutrition?
  }

  public let recipeID: Int64
  /// Validated serving denominator from the fetched recipe row.
  public let recipeServings: Int
  /// Calories per serving of the recipe as planned (original ingredients, recipe servings),
  /// as the recommendation scored it. Nil when that read was unavailable.
  public let referenceCaloriesPerServing: Double?
  public let rows: [Row]

  public init(
    recipeID: Int64,
    recipeServings: Int,
    referenceCaloriesPerServing: Double?,
    rows: [Row]
  ) {
    self.recipeID = recipeID
    self.recipeServings = recipeServings
    self.referenceCaloriesPerServing = referenceCaloriesPerServing
    self.rows = rows
  }
}

// MARK: - Failure

/// Why the review refused to show amounts. Every case is a state the UI renders as a
/// retry or refusal — none of them is ever papered over with fabricated amounts.
public enum RecipeQuantityReviewFailure: Error, Equatable, Sendable {
  /// The recipe had no persisted ID, so no single identity can be validated.
  case missingRecipeID
  /// The validated ID fetched no recipe row.
  case recipeNotFound(Int64)
  /// The recipe has no ingredient rows at all.
  case noIngredientRows
  /// Rows disagree about the recipe, repeat an ingredient, or carry unusable numbers.
  case inconsistentRows(String)
  /// The fetched recipe's serving denominator cannot be a denominator.
  case invalidRecipeServings(Int)
  /// A read failed (for example the database is unreadable). Retryable.
  case readFailed(String)
}
