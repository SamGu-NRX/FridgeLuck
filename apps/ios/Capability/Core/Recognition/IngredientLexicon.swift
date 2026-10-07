import Foundation

/// Maps Vision taxonomy labels, OCR text, and common synonyms to ingredient database IDs.
/// This is intentionally code (not JSON) because it is mapping logic.
enum IngredientLexicon {
  struct OCRTextMatch: Sendable {
    let ingredientId: Int64
    let kind: OCRMatchKind
    let matchedToken: String
  }

  // MARK: - Vision label → ingredient ID

  /// Maps VNClassifyImageRequest taxonomy labels to ingredient database IDs.
  /// Only labels that identify a supported food are mapped.
  private static let labelToId: [String: Int64] = [
    // Eggs
    "egg": 1, "fried_egg": 1,

    // Grains
    "rice": 2,
    "pasta": 9,
    "oatmeal": 31,
    "bread": 15, "naan": 15,
    "tortilla": 28,

    // Protein
    "chicken": 4, "grilled_chicken": 4, "fried_chicken": 4,
    "beef": 38,
    "salmon": 36,
    "tofu": 23,

    // Vegetables
    "onion": 5,
    "garlic": 6,
    "tomato": 7,
    "bell_pepper": 8, "pepper_veggie": 8,
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
    "pea": 42,
    "avocado": 26,

    // Fruits
    "banana": 20,
    "apple": 40,
    "lemon": 17, "lime": 29,

    // Dairy
    "cheese": 12,
    "milk": 13,
    "butter": 14,
    "yogurt": 32,

    // Legumes
    "black_beans": 27,
    "chickpea": 35,

    // Condiments & oils
    "soy_sauce": 3,
    "olive_oil": 16,
    "sesame_oil": 22,
    "honey": 33,
    "peanut_butter": 41,

    // Herbs & spices
    "cilantro": 48, "green_onion": 21,
    "ginger": 30,

    // Canned
    "canned_tuna": 43,

    // Coconut
    "coconut_milk": 49,
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
    "scallion": "green_onion",
    "spring onion": "green_onion",
    "green onion": "green_onion",
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
    "soy sauce": "soy_sauce",
    "olive oil": "olive_oil",
    "sesame oil": "sesame_oil",
    "peanut butter": "peanut_butter",
    "canned tuna": "canned_tuna",
    "tuna": "canned_tuna",
    "ground beef": "beef",
    "chicken breast": "chicken",
    "frozen peas": "pea",
    "sweet potato": "sweet_potato",
    "black beans": "black_beans",
    "chickpeas": "chickpea",
    "garbanzo beans": "chickpea",
    "coconut milk": "coconut_milk",
  ]

  // These foods have no curated ingredient. Mask whole phrases before OCR lookup so
  // "oat milk" cannot fall through to an exact match for dairy "milk".
  private static let unsupportedFoodPhrases = [
    "green beans", "citrus fruit", "oat milk", "soy milk",
    "vegetable oil", "almond butter", "chicken thigh", "kidney beans",
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
    resolveFromTextDetailed(ocrText)?.ingredientId
  }

  /// Resolve OCR text with match quality for source-aware confidence routing.
  static func resolveFromTextDetailed(_ ocrText: String) -> OCRTextMatch? {
    let normalizedText = maskingUnsupportedFoodPhrases(ocrText)
    guard !normalizedText.isEmpty else { return nil }

    let synonymCandidates = synonyms.keys.sorted { lhs, rhs in
      if lhs.count == rhs.count { return lhs < rhs }
      return lhs.count > rhs.count
    }
    for phrase in synonymCandidates {
      guard containsWholePhrase(normalizedText, phrase: phrase),
        let canonical = synonyms[phrase],
        let id = labelToId[canonical]
      else { continue }
      return OCRTextMatch(ingredientId: id, kind: .exact, matchedToken: phrase)
    }

    let labelCandidates = labelToId.keys.sorted { lhs, rhs in
      if lhs.count == rhs.count { return lhs < rhs }
      return lhs.count > rhs.count
    }
    for label in labelCandidates {
      let readable = label.replacingOccurrences(of: "_", with: " ")
      guard containsWholePhrase(normalizedText, phrase: readable),
        let id = labelToId[label]
      else { continue }
      return OCRTextMatch(ingredientId: id, kind: .exact, matchedToken: readable)
    }

    let tokens = normalizedText.split(separator: " ").map(String.init)
    for token in tokens where token.count >= 4 {
      guard let id = resolve(token) else { continue }
      return OCRTextMatch(ingredientId: id, kind: .fuzzy, matchedToken: token)
    }

    return nil
  }

  /// Get a human-readable display name for an ingredient ID.
  static func displayName(for ingredientId: Int64) -> String {
    displayNames[ingredientId] ?? "Unknown"
  }

  /// Unsupported food phrases (singular or plural) that appear in `text`, in reading order.
  static func unsupportedFoodPhrases(in text: String) -> [String] {
    scanUnsupportedPhrases(in: text).found
  }

  /// Normalized `text` with every unsupported food phrase removed, so "oat milk" can't fall
  /// through to a single-word match for dairy "milk". Token-based, so repeats and plurals
  /// ("oat milk oat milk", "chicken thighs") are masked too.
  static func maskingUnsupportedFoodPhrases(_ text: String) -> String {
    scanUnsupportedPhrases(in: text).kept.joined(separator: " ")
  }

  private static func scanUnsupportedPhrases(in text: String) -> (kept: [String], found: [String]) {
    let tokens = normalizeOCRText(text).split(separator: " ").map(String.init)
    let phrases = unsupportedFoodPhrases.map { $0.split(separator: " ").map(String.init) }
    var kept: [String] = []
    var found: [String] = []
    var index = 0
    while index < tokens.count {
      let match = phrases.first { phrase in
        guard index + phrase.count <= tokens.count else { return false }
        for (offset, word) in phrase.enumerated() {
          let token = tokens[index + offset]
          let isLast = offset == phrase.count - 1
          if token == word || (isLast && (token == word + "s" || token == word + "es")) {
            continue
          }
          return false
        }
        return true
      }
      if let match {
        found.append(match.joined(separator: " "))
        index += match.count
      } else {
        kept.append(tokens[index])
        index += 1
      }
    }
    return (kept, found)
  }

  private static func normalizeOCRText(_ text: String) -> String {
    let lowered = text.lowercased()
    let components = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    return components.joined(separator: " ")
  }

  private static func containsWholePhrase(_ normalizedText: String, phrase: String) -> Bool {
    let normalizedPhrase = normalizeOCRText(phrase)
    guard !normalizedPhrase.isEmpty else { return false }
    let paddedText = " \(normalizedText) "
    return paddedText.contains(" \(normalizedPhrase) ")
  }
}
