import FLFeatureLogic
import Foundation

/// One row of the recipe preview's ingredient list.
///
/// The preview used to list only catalog lines that bridge to an app ingredient and mark each
/// by the first ingredient id it bridges to. A line with no bridge never showed, though the
/// results card counted it missing; a line whose stock sat on another bridged id showed a plain
/// check while the card said "short"; and assumed staples showed checks the kitchen never
/// confirmed. Catalog rows now take the search's own per-line mark.
struct RecipePreviewIngredientRow: Identifiable {
  let id: String
  let name: String
  let quantityText: String
  let isRequired: Bool
  /// The row's position among a catalog recipe's lines, which indexes
  /// `ScoredRecipe.catalogLineMarks`. nil for a legacy row.
  let catalogLineIndex: Int?
  /// The app ingredient the row opens and swaps, or nil for a catalog line no app ingredient
  /// stands for.
  let linked: (ingredient: Ingredient, quantity: RecipeIngredient)?

  /// The mark the recipe search behind `scored` gives this row.
  func mark(in scored: ScoredRecipe, isSubstituted: Bool) -> RecipeIngredientMark {
    if isSubstituted { return .substituted }
    if let catalogLineIndex {
      // Both lists come from one database read order (line position); a result built before
      // the catalog changed under it makes no claim rather than borrow another line's mark.
      guard scored.catalogLineMarks.indices.contains(catalogLineIndex) else { return .optional }
      return scored.catalogLineMarks[catalogLineIndex]
    }
    guard let ingredientID = linked?.quantity.ingredientId else { return .optional }
    return .mark(
      ingredientID: ingredientID,
      isRequired: isRequired,
      isSubstituted: false,
      missingRequiredIDs: Set(scored.missingIngredientIds),
      insufficientSupply: scored.insufficientSupplyByIngredientID)
  }
}

enum RecipePreviewIngredientRows {
  /// Every line of a catalog recipe in recipe order, named as the results card names it.
  static func catalog(
    _ packet: RecipeCatalogCookPacket, ingredientsByID: [Int64: Ingredient]
  ) -> [RecipePreviewIngredientRow] {
    packet.lines.enumerated().map { index, line in
      let linked: (ingredient: Ingredient, quantity: RecipeIngredient)? =
        line.bridgedIngredientId.flatMap { id in
          ingredientsByID[id].map { ingredient in
            (
              ingredient: ingredient,
              quantity: RecipeIngredient(
                recipeId: 0,
                ingredientId: id,
                isRequired: line.required,
                quantityGrams: RecipeRepository.quantityGrams(line.quantity) ?? 0,
                displayQuantity: RecipeRepository.quantityText(line.quantity)
              )
            )
          }
        }
      return RecipePreviewIngredientRow(
        id: "line-\(index)",
        name: RecipeRepository.catalogLineName(key: line.key, displayName: line.displayName),
        quantityText: RecipeRepository.quantityText(line.quantity),
        isRequired: line.required,
        catalogLineIndex: index,
        linked: linked)
    }
  }

  /// A legacy recipe's rows: one app ingredient per line.
  static func legacy(
    _ items: [(ingredient: Ingredient, quantity: RecipeIngredient)]
  ) -> [RecipePreviewIngredientRow] {
    items.map { item in
      RecipePreviewIngredientRow(
        id: "ingredient-\(item.quantity.ingredientId)",
        name: item.ingredient.displayName,
        quantityText: item.quantity.displayQuantity,
        isRequired: item.quantity.isRequired,
        catalogLineIndex: nil,
        linked: item)
    }
  }
}
