import Foundation

/// A substitution the cook actually made: `substituteIngredientId` replaced
/// `originalIngredientId`, using `ratio` times the recipe's grams.
struct IngredientSwap: Sendable, Hashable {
  let originalIngredientId: Int64
  let substituteIngredientId: Int64
  let ratio: Double
}
