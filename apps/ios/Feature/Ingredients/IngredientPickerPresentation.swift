import Foundation

/// Text and identity rules shared by the manual ingredient picker.
enum IngredientPickerPresentation {
  static func subtitle(for ingredient: Ingredient) -> String {
    let category: String
    switch ingredient.categoryLabel?.lowercased() {
    case "protein": category = "Protein"
    case "vegetable": category = "Vegetable"
    case "fruit": category = "Fruit"
    case "grain_legume": category = "Grain or legume"
    case "dairy_egg": category = "Dairy or egg"
    case "oil_fat": category = "Oil or fat"
    case "herb_spice": category = "Herb or spice"
    case "nut_seed": category = "Nut or seed"
    case "condiment": category = "Condiment"
    case "sweetener_baking": category = "Sweetener or baking"
    case "fungi": category = "Mushroom"
    default: category = "Ingredient"
    }
    return "\(category) · nutrition per 100 g"
  }

  static func accessibilityLabel(for ingredient: Ingredient) -> String {
    let calories = Int(ingredient.calories.rounded())
    return "\(ingredient.displayName), \(subtitle(for: ingredient)), \(calories) kilocalories per 100 grams"
  }

  /// Removes only rows that represent the same food and report effectively the same nutrition.
  /// A cooked, frozen, or otherwise different variant remains visible.
  static func deduplicate(_ ingredients: [Ingredient]) -> [Ingredient] {
    var result: [Ingredient] = []
    for ingredient in ingredients {
      guard let duplicateIndex = result.firstIndex(where: { equivalent($0, ingredient) }) else {
        result.append(ingredient)
        continue
      }

      if variantRank(of: ingredient) < variantRank(of: result[duplicateIndex]) {
        result[duplicateIndex] = ingredient
      }
    }
    return result
  }

  static func grouped(_ ingredients: [Ingredient]) -> [(letter: String, ingredients: [Ingredient])] {
    let unique = deduplicate(ingredients)
    let groups = Dictionary(grouping: unique) { ingredient in
      let first = ingredient.displayName.prefix(1).uppercased()
      return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
    }
    return groups.sorted { $0.key < $1.key }
      .map { (letter: $0.key, ingredients: $0.value) }
  }

  private static func equivalent(_ lhs: Ingredient, _ rhs: Ingredient) -> Bool {
    guard baseName(lhs.displayName) == baseName(rhs.displayName) else { return false }
    return abs(lhs.calories - rhs.calories) <= 1
      && abs(lhs.protein - rhs.protein) <= 0.1
      && abs(lhs.carbs - rhs.carbs) <= 0.1
      && abs(lhs.fat - rhs.fat) <= 0.1
      && abs(lhs.fiber - rhs.fiber) <= 0.1
      && abs(lhs.sugar - rhs.sugar) <= 0.1
      && abs(lhs.sodium - rhs.sodium) <= 0.01
  }

  private static func baseName(_ name: String) -> String {
    name
      .lowercased()
      .replacingOccurrences(of: "(raw)", with: "")
      .replacingOccurrences(of: "  ", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func variantRank(of ingredient: Ingredient) -> Int {
    ingredient.displayName.contains("(") ? 1 : 0
  }
}
