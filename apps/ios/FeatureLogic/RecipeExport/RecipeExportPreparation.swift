import Foundation

/// Validation, single-pass serving scaling, and per-row quantity text.
enum RecipeExportPreparation {
  static func prepare(
    intake: RecipeExportIntake,
    exportedServings: Double,
    presentation: RecipeExportQuantityPresentation
  ) throws -> RecipeExportPrepared {
    guard exportedServings.isFinite, exportedServings > 0 else {
      throw RecipeExportError.invalidExportServings(exportedServings)
    }
    guard let baseServings = intake.originalServings, baseServings > 0 else {
      throw RecipeExportError.invalidOriginalServings(intake.originalServings)
    }
    guard !intake.recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecipeExportError.inconsistentRecipeRead("recipe name missing")
    }
    for row in intake.rows {
      guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RecipeExportError.inconsistentRecipeRead("ingredient name missing")
      }
      // !(ratio > 0) also rejects NaN, which "ratio <= 0" alone would let through.
      if let ratio = row.substitutionRatio, !(ratio.isFinite && ratio > 0) {
        throw RecipeExportError.inconsistentRecipeRead("substitution ratio invalid")
      }
      // !(amount >= 0) treats a NaN reading as an inconsistent (negative-adjacent) read.
      if let amount = row.amount, !(amount >= 0) {
        throw RecipeExportError.inconsistentRecipeRead("ingredient amount negative")
      }
    }

    // Scale is applied exactly once; the substitution ratio rides on top of it.
    let scale = exportedServings / Double(baseServings)
    var preparedRows: [RecipeExportPreparedRow] = []
    preparedRows.reserveCapacity(intake.rows.count)
    for row in intake.rows {
      let quantityText: String
      if let amount = row.amount {
        let effective = amount * scale * (row.substitutionRatio ?? 1)
        quantityText = RecipeExportQuantityText.quantityText(
          effectiveAmount: effective,
          unit: row.unit,
          presentation: presentation
        )
      } else {
        // No gram quantity recorded: say so rather than inventing a number.
        quantityText = "unspecified"
      }
      preparedRows.append(RecipeExportPreparedRow(
        name: row.name,
        isRequired: row.isRequired,
        replacementNote: row.replacementNote,
        substitutedName: row.substitutedName,
        substitutionRatio: row.substitutionRatio,
        quantityText: quantityText
      ))
    }

    return RecipeExportPrepared(
      recipeName: intake.recipeName,
      originalServings: baseServings,
      exportedServings: exportedServings,
      presentation: presentation,
      rows: preparedRows,
      sourceURL: exportableSourceURL(intake.sourceURL),
      capturedInputs: intake
    )
  }

  /// Only http(s) links may leave the device; anything else (or schemeless) drops.
  private static func exportableSourceURL(_ url: URL?) -> URL? {
    guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }
    return url
  }
}

enum RecipeExportQuantityText {
  /// Ounces conversion factor: exactly one pound is 453.59237 g, so 1 oz is
  /// 28.349523125 g. Only gram quantities convert; every other unit passes through.
  private static let gramsPerOunce = 28.349523125

  static func quantityText(
    effectiveAmount: Double,
    unit: String?,
    presentation: RecipeExportQuantityPresentation
  ) -> String {
    let trimmedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
    let isGramQuantity = trimmedUnit.map { unit in
      ["g", "gram", "grams"].contains(unit.lowercased())
    } ?? false
    switch presentation {
    case .metricGrams:
      if isGramQuantity { return RecipeExportNumberText.amount(effectiveAmount) + " g" }
      return passThroughText(effectiveAmount, unit: trimmedUnit)
    case .imperialOunces:
      if isGramQuantity {
        return RecipeExportNumberText.amount(effectiveAmount / gramsPerOunce) + " oz"
      }
      return passThroughText(effectiveAmount, unit: trimmedUnit)
    }
  }

  /// Non-gram units keep their text after scaling; a unitless amount is a bare number.
  private static func passThroughText(_ amount: Double, unit: String?) -> String {
    guard let unit, !unit.isEmpty else { return RecipeExportNumberText.amount(amount) }
    return RecipeExportNumberText.amount(amount) + " " + unit
  }
}
