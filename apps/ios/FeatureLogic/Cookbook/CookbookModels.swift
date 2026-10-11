import Foundation

/// A single ingredient line on a cookbook recipe draft: which catalog ingredient,
/// how many grams, and whether the dish falls apart without it.
///
/// Grams are the canonical amount (matching `recipe_ingredients.quantity_grams`);
/// `displayQuantity` is optional derived text ("120g", "2 cups") the editor may pin,
/// otherwise the persistence layer derives a plain gram string.
public struct CookbookIngredientLine: Sendable, Equatable {
  public var ingredientId: Int64
  public var grams: Double
  public var isRequired: Bool
  public var displayQuantity: String?

  public init(ingredientId: Int64, grams: Double, isRequired: Bool, displayQuantity: String? = nil) {
    self.ingredientId = ingredientId
    self.grams = grams
    self.isRequired = isRequired
    self.displayQuantity = displayQuantity
  }
}

/// What the user is editing before a save: pure values, no identity.
///
/// A draft is NOT a saved recipe. Identity is assigned by the persistence layer
/// (`UserRecipeTransactionService`) as a `recipes` row with `source = 'user'`;
/// a cooked entry is a `cooking_history` row the journal owns. Nothing here
/// carries a rating — ratings belong to cooked entries, not to cookbook recipes.
public struct CookbookRecipeDraft: Sendable, Equatable {
  public var title: String
  public var timeMinutes: Int
  public var servings: Int
  public var instructions: String
  public var tagMask: Int
  public var ingredientLines: [CookbookIngredientLine]

  public init(
    title: String,
    timeMinutes: Int,
    servings: Int,
    instructions: String,
    tagMask: Int = 0,
    ingredientLines: [CookbookIngredientLine] = []
  ) {
    self.title = title
    self.timeMinutes = timeMinutes
    self.servings = servings
    self.instructions = instructions
    self.tagMask = tagMask
    self.ingredientLines = ingredientLines
  }
}

/// One validation finding about a draft. The editor lists every problem at once
/// so a failed save is fixable in a single pass rather than one error per retry.
public enum CookbookValidationProblem: Error, Sendable, Equatable {
  case emptyTitle
  case titleTooLong(limit: Int)
  case invalidTimeMinutes(Int)
  case invalidServings(Int)
  case emptyInstructions
  case noIngredientLines
  /// Quantity is not a finite positive number (NaN, infinite, zero, or negative).
  case invalidQuantity(ingredientId: Int64)
  case duplicateIngredient(ingredientId: Int64)
  /// The draft references ingredient ids the catalog does not contain.
  case unknownIngredients([Int64])
}

/// Identity vocabulary for the cookbook, kept explicit so store code can never
/// blur the two histories that meet in this feature:
///
/// - A **saved recipe** is a cookbook record: either a `recipes` row the user
///   authored (`source = 'user'`) or a sidecar registration pointing at a
///   shared catalog row. It has no date-it-was-cooked and no rating.
/// - A **cooked entry** is a `cooking_history` row the cooking journal owns.
///   The cookbook reads it only to display "cooked N times"; it never writes it.
public enum CookbookIdentity {
  /// Provenance stamped on every recipe row the cookbook creates. The bundled
  /// refresh only ever adopts, updates, or blocks on `source = 'bundled'` rows,
  /// so this value is the structural guarantee that a user recipe can never be
  /// adopted (stolen) by a bundle refresh.
  public static let userSourceRawValue = "user"
}
