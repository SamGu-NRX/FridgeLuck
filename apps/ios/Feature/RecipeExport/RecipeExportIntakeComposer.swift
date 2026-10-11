import FLFeatureLogic
import Foundation

/// Maps the recipe preview's live state into the FLFeatureLogic export intake.
///
/// Only pure mapping lives here; the fresh repository read that feeds it happens
/// in the drawer, so a swallowed load error can never reach the export.
enum RecipeExportIntakeComposer {
  /// - Parameters:
  ///   - rows: freshly read ingredient rows for the recipe.
  ///   - substitutions: active swaps keyed by the original ingredient's id.
  ///   - photoPath: the recipe's stored photo path if accessible, otherwise "".
  static func compose(
    recipe: Recipe,
    rows: [(ingredient: Ingredient, quantity: RecipeIngredient)],
    substitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)],
    photoPath: String
  ) -> RecipeExportIntake {
    let exportRows = rows.map { row -> RecipeExportRowIntake in
      let grams = row.quantity.quantityGrams
      // Canonical amount is quantityGrams in 'g'; displayQuantity stays out of
      // the numeric path. A missing/zero gram amount exports as unspecified.
      let hasAmount = grams > 0
      let active = substitutions[row.ingredient.id ?? -1]
      return RecipeExportRowIntake(
        name: row.ingredient.displayName,
        isRequired: row.quantity.isRequired,
        amount: hasAmount ? grams : nil,
        unit: hasAmount ? "g" : nil,
        replacementNote: active?.substitution.note,
        substitutedName: active?.ingredient.displayName,
        substitutionRatio: active?.substitution.ratio
      )
    }

    // The source URL comes only from the existing attribution parser. Its url
    // is set exclusively for http(s) links, so nothing is guessed here.
    let sourceURL = CookingGuideSteps(instructions: recipe.instructions).attribution?.url

    return RecipeExportIntake(
      recipeName: recipe.title,
      originalServings: recipe.servings,
      sourceURL: sourceURL,
      rows: exportRows,
      excluded: RecipeExportExcludedFields(
        photoPath: photoPath,
        journalNotes: "",
        healthSummary: "",
        rating: "",
        databaseID: recipe.id.map { String($0) } ?? "",
        instructions: recipe.instructions,
        ocrText: ""
      )
    )
  }
}
