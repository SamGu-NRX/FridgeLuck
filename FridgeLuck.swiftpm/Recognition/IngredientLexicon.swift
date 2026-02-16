import Foundation

/// Maps Vision taxonomy labels, OCR text, and common synonyms to ingredient database IDs.
/// This is intentionally code (not JSON) because it is mapping logic.
enum IngredientLexicon {
  // MARK: - Vision label → ingredient ID

  /// Maps VNClassifyImageRequest taxonomy labels to ingredient database IDs.
  /// Covers ~150 food-related labels from the 1,303-label taxonomy.
  private static let labelToId: [String: Int64] = [
    // Eggs
    "egg": 1, "fried_egg": 1,

    // Grains
    "rice": 2, "grain": 2,
    "pasta": 9,
    "oatmeal": 31, "cereal": 31,
    "bread": 15, "naan": 15,
    "tortilla": 28,

    // Protein
    "chicken": 4, "grilled_chicken": 4, "fried_chicken": 4,
    "beef": 38, "meat": 38, "meatball": 38,
    "salmon": 36, "fish": 36, "mackerel": 36,
    "tofu": 23,
    "ham": 38,

    // Vegetables
    "onion": 5,
    "garlic": 6,
    "tomato": 7,
    "bell_pepper": 8, "pepper_veggie": 8, "habanero": 8, "jalapeno": 8,
    "potato": 10, "sweet_potato": 37,
    "carrot": 11,
    "mushroom": 18,
    "spinach": 19,
    "broccoli": 24,
    "cucumber": 25,
    "lettuce": 39,
    "celery": 44,
    "zucchini": 45,
    "corn": 34,
    "green_beans": 42, "edamame": 42,
    "pea": 42,
    "avocado": 26,

    // Fruits
    "banana": 20,
    "apple": 40,
    "lemon": 17, "lime": 29,
    "oranges": 17, "citrus_fruit": 17,

    // Dairy
    "cheese": 12, "caprese": 12,
    "milk": 13, "milkshake": 13,
    "butter": 14,
    "yogurt": 32,

    // Legumes
    "bean": 27,
    "chickpea": 35, "hummus": 35, "falafel": 35,

    // Condiments & oils
    "condiment": 3,
    "mustard": 3,
    "soy_sauce": 3,
    "olive_oil": 16,
    "sesame_oil": 22,
    "honey": 33,
    "peanut": 41,

    // Herbs & spices
    "herb": 48, "cilantro": 48, "dill": 48, "chives": 21,
    "ginger": 30,

    // Canned
    "canned_tuna": 43,

    // Coconut
    "coconut": 49,
  ]

  // MARK: - Synonym normalization

  /// Maps common names, OCR text, plurals, and regional variations to canonical label keys.
  private static let synonyms: [String: String] = [
    // Plurals
    "eggs": "egg",
    "tomatoes": "tomato",
    "potatoes": "potato",
    "carrots": "carrot",
    "mushrooms": "mushroom",
    "onions": "onion",
    "bananas": "banana",
    "apples": "apple",
    "lemons": "lemon",
    "limes": "lime",

    // Regional / alternative names
    "capsicum": "bell_pepper",
    "red pepper": "bell_pepper",
    "green pepper": "bell_pepper",
    "scallion": "chives",
    "spring onion": "chives",
    "green onion": "chives",
    "courgette": "zucchini",

    // Brand / packaging text
    "large egg": "egg",
    "large eggs": "egg",
    "greek yogurt": "yogurt",
    "plain yogurt": "yogurt",
    "cheddar": "cheese",
    "mozzarella": "cheese",
    "parmesan": "cheese",
    "2% milk": "milk",
    "whole milk": "milk",
    "skim milk": "milk",
    "oat milk": "milk",
    "soy milk": "milk",
    "soy sauce": "soy_sauce",
    "olive oil": "olive_oil",
    "sesame oil": "sesame_oil",
    "vegetable oil": "olive_oil",
    "peanut butter": "peanut",
    "almond butter": "peanut",
    "canned tuna": "canned_tuna",
    "tuna": "canned_tuna",
    "ground beef": "beef",
    "chicken breast": "chicken",
    "chicken thigh": "chicken",
    "frozen peas": "pea",
    "sweet potato": "sweet_potato",
    "black beans": "bean",
    "kidney beans": "bean",
    "chickpeas": "chickpea",
    "garbanzo beans": "chickpea",
    "coconut milk": "coconut",
  ]

  // MARK: - Display names (ingredient ID → human-readable name)

  private static let displayNames: [Int64: String] = [
    1: "Egg", 2: "Rice", 3: "Soy Sauce", 4: "Chicken Breast",
    5: "Onion", 6: "Garlic", 7: "Tomato", 8: "Bell Pepper",
    9: "Pasta", 10: "Potato", 11: "Carrot", 12: "Cheese",
    13: "Milk", 14: "Butter", 15: "Bread", 16: "Olive Oil",
    17: "Lemon", 18: "Mushroom", 19: "Spinach", 20: "Banana",
    21: "Green Onion", 22: "Sesame Oil", 23: "Tofu", 24: "Broccoli",
    25: "Cucumber", 26: "Avocado", 27: "Black Beans", 28: "Tortilla",
    29: "Lime", 30: "Ginger", 31: "Oats", 32: "Yogurt",
    33: "Honey", 34: "Corn", 35: "Chickpea", 36: "Salmon",
    37: "Sweet Potato", 38: "Ground Beef", 39: "Lettuce", 40: "Apple",
    41: "Peanut Butter", 42: "Frozen Peas", 43: "Canned Tuna",
    44: "Celery", 45: "Zucchini", 46: "Red Pepper Flakes",
    47: "Cumin", 48: "Cilantro", 49: "Coconut Milk", 50: "Sour Cream",
  ]

  // MARK: - Public API

  /// Resolve a Vision label or user text to an ingredient database ID.
  static func resolve(_ label: String) -> Int64? {
    let normalized = label.lowercased()
      .trimmingCharacters(in: .whitespaces)

    // Direct lookup (handles both underscore and space-separated)
    let underscored = normalized.replacingOccurrences(of: " ", with: "_")
    if let id = labelToId[underscored] { return id }
    if let id = labelToId[normalized] { return id }

    // Synonym lookup
    if let canonical = synonyms[normalized],
      let id = labelToId[canonical]
    {
      return id
    }

    // Try basic de-pluralization
    let singular: String
    if normalized.hasSuffix("ies") {
      singular = String(normalized.dropLast(3)) + "y"
    } else if normalized.hasSuffix("es") {
      singular = String(normalized.dropLast(2))
    } else if normalized.hasSuffix("s") {
      singular = String(normalized.dropLast())
    } else {
      singular = normalized
    }

    if singular != normalized {
      let singularUnderscored = singular.replacingOccurrences(of: " ", with: "_")
      if let id = labelToId[singularUnderscored] { return id }
      if let id = labelToId[singular] { return id }
    }

    return nil
  }

  /// Search OCR text for any known ingredient name.
  static func resolveFromText(_ ocrText: String) -> Int64? {
    let lowered = ocrText.lowercased()

    // Check synonyms first (they contain common packaging text)
    for (phrase, canonical) in synonyms {
      if lowered.contains(phrase), let id = labelToId[canonical] {
        return id
      }
    }

    // Check direct label names
    for (name, id) in labelToId {
      let readable = name.replacingOccurrences(of: "_", with: " ")
      if lowered.contains(readable) {
        return id
      }
    }

    return nil
  }

  /// Get a human-readable display name for an ingredient ID.
  static func displayName(for ingredientId: Int64) -> String {
    displayNames[ingredientId] ?? "Unknown"
  }
}
