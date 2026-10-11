import Foundation

/// Raised when the incoming bundle payload fails validation. Lists every problem
/// found so a bundle regression is actionable in one CI run, not one per launch.
struct BundledDataValidationError: Error, CustomStringConvertible {
  let problems: [String]

  var description: String {
    "BundledDataValidationError: \(problems.joined(separator: "; "))"
  }
}

/// Validates an incoming bundle payload before the refresh writes any of it.
///
/// The decoder already enforces the positional JSON shape; these are the semantic
/// checks a wrong correction could still violate. The refresh refuses the whole
/// payload when anything fails: a bundle that half-validates must never reach
/// installed rows.
enum BundledDataValidator {
  static func validate(_ bundled: BundledData) throws {
    var problems: [String] = []

    var namesByNormalizedName: [String: Int] = [:]
    for (idString, raw) in bundled.ingredients {
      guard let id = Int(idString) else {
        problems.append("ingredient key \(idString) is not an integer id")
        continue
      }
      if normalizedKey(raw.name) == nil {
        problems.append("ingredient \(id) has a blank name")
      }
      for (field, value) in [
        ("calories", raw.calories), ("protein", raw.protein), ("carbs", raw.carbs),
        ("fat", raw.fat), ("fiber", raw.fiber), ("sugar", raw.sugar), ("sodium", raw.sodium),
      ] {
        if !value.isFinite || value < 0 {
          problems.append("ingredient \(id) (\(raw.name)) has non-finite or negative \(field)")
        }
      }
      if let normalized = normalizedKey(raw.name) {
        if let previousId = namesByNormalizedName[normalized] {
          problems.append(
            "ingredient \(id) (\(raw.name)) duplicates the name of ingredient \(previousId)")
        } else {
          namesByNormalizedName[normalized] = id
        }
      }
    }

    var titlesByNormalizedTitle: [String: Int] = [:]
    for raw in bundled.recipes {
      if normalizedKey(raw.title) == nil {
        problems.append("recipe \(raw.id) has a blank title")
      }
      if raw.timeMinutes < 1 {
        problems.append("recipe \(raw.id) (\(raw.title)) has time_minutes \(raw.timeMinutes) < 1")
      }
      if raw.servings < 1 {
        problems.append("recipe \(raw.id) (\(raw.title)) has servings \(raw.servings) < 1")
      }
      if raw.tagBitmask < 0 {
        problems.append("recipe \(raw.id) (\(raw.title)) has a negative tag bitmask")
      }
      if raw.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        problems.append("recipe \(raw.id) (\(raw.title)) has blank instructions")
      }
      for pair in raw.requiredIngredients {
        checkIngredientPair(
          pair, recipe: raw, required: true, ingredients: bundled.ingredients, into: &problems)
      }
      for pair in raw.optionalIngredients {
        checkIngredientPair(
          pair, recipe: raw, required: false, ingredients: bundled.ingredients, into: &problems)
      }
      if let normalized = normalizedKey(raw.title) {
        if let previousId = titlesByNormalizedTitle[normalized] {
          problems.append(
            "recipe \(raw.id) (\(raw.title)) duplicates the title of recipe \(previousId)")
        } else {
          titlesByNormalizedTitle[normalized] = raw.id
        }
      }
    }

    guard problems.isEmpty else {
      throw BundledDataValidationError(problems: problems)
    }
  }

  private static func checkIngredientPair(
    _ pair: (id: Int, grams: Double),
    recipe: RecipeArray,
    required: Bool,
    ingredients: [String: IngredientArray],
    into problems: inout [String]
  ) {
    let kind = required ? "required" : "optional"
    guard ingredients[String(pair.id)] != nil else {
      problems.append(
        "recipe \(recipe.id) (\(recipe.title)) references missing \(kind) ingredient \(pair.id)")
      return
    }
    if !pair.grams.isFinite || pair.grams <= 0 {
      problems.append(
        "recipe \(recipe.id) (\(recipe.title)) has non-finite or non-positive grams for "
          + "\(kind) ingredient \(pair.id)")
    }
  }

  /// Shared case- and whitespace-insensitive key. Recipes already key hydration on
  /// it; using it for validation and adoption matching keeps all three consistent.
  static func normalizedKey(_ text: String) -> String? {
    let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return key.isEmpty ? nil : key
  }
}
