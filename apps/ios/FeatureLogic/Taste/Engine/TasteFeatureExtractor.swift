import Foundation

/// Deterministic taste-feature extraction over the app's catalog — the Swift
/// port of the lab's documented proxy extractor
/// (`evaluation/taste-lab/taste_lab/features.py` for the documented
/// taste-features-v1 pipeline). Feature keys are deterministic functions of
/// the catalog; the golden fixtures pin the lab's outputs, and this port must
/// reproduce them exactly for the fixture replay to hold.
///
/// Pure Swift: no GRDB. The app feeds it catalog rows; the tests feed it the
/// bundled positional `data.json`.
public struct TasteFeatureExtractor: Sendable {
  // MARK: Inputs

  public struct RecipeInput: Sendable {
    public let id: String
    public let title: String
    public let timeMinutes: Int
    public let servings: Int
    public let instructions: String
    /// The RecipeTags bit mask (bit order mirrors Recipe.swift RecipeTags).
    public let tagBitmask: Int
    /// Required ingredients: (ingredient id, grams).
    public let required: [(id: String, grams: Double)]
    public let optional: [(id: String, grams: Double)]

    public init(
      id: String, title: String, timeMinutes: Int, servings: Int, instructions: String,
      tagBitmask: Int, required: [(id: String, grams: Double)],
      optional: [(id: String, grams: Double)] = []
    ) {
      self.id = id
      self.title = title
      self.timeMinutes = timeMinutes
      self.servings = servings
      self.instructions = instructions
      self.tagBitmask = tagBitmask
      self.required = required
      self.optional = optional
    }
  }

  public struct IngredientInput: Sendable {
    public let id: String
    public let name: String
    // Per 100 g.
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let fiber: Double
    public let sugar: Double
    public let sodium: Double

    public init(
      id: String, name: String, calories: Double, protein: Double, carbs: Double,
      fat: Double, fiber: Double, sugar: Double, sodium: Double
    ) {
      self.id = id
      self.name = name
      self.calories = calories
      self.protein = protein
      self.carbs = carbs
      self.fat = fat
      self.fiber = fiber
      self.sugar = sugar
      self.sodium = sodium
    }
  }

  // MARK: Tag bit order (Recipe.swift RecipeTags)

  public static let tagBits: [(bit: Int, name: String)] = [
    (1 << 0, "quick"), (1 << 1, "vegetarian"), (1 << 2, "vegan"), (1 << 3, "asian"),
    (1 << 4, "breakfast"), (1 << 5, "budget"), (1 << 6, "comfort"), (1 << 7, "mediterranean"),
    (1 << 8, "mexican"), (1 << 9, "high_protein"), (1 << 10, "low_carb"), (1 << 11, "one_pot"),
  ]
  static let cuisineTags: Set<String> = ["asian", "mediterranean", "mexican"]
  static let techniqueKeywords: [(name: String, words: [String])] = [
    ("stir_fry", ["stir-fry", "stir fry", "wok", "sauté", "saute", "stir-fries"]),
    ("bake", ["bake", "oven", "preheat"]),
    ("grill", ["grill"]),
    ("steam", ["steam"]),
    ("boil", ["boil", "blanch"]),
    ("roast", ["roast"]),
    ("simmer", ["simmer", "braise"]),
    ("marinate", ["marinate", "marinade"]),
  ]
  static let spicyPatterns = [
    "chili", "chilli", "pepper flake", "sriracha", "sambal", "cayenne", "hot sauce",
    "jalape", "harissa", "gochujang", "curry paste",
  ]

  let ingredients: [String: IngredientInput]

  public init(ingredients: [String: IngredientInput]) {
    self.ingredients = ingredients
  }

  // MARK: Extraction

  /// Fills the feature keys (canonical sorted order) and display names for one
  /// recipe. Feature classes: ingredient, cuisine, technique, time, nutrient,
  /// spice, tool, other (SPEC 2.1).
  public func features(for recipe: RecipeInput) -> (keys: [String], names: [String: String]) {
    var keys: Set<String> = []
    var names: [String: String] = [:]

    // ingredient:<id> — required ingredients only (the app trains on what the
    // meal actually used; optional garnishes are weak identity signal).
    for (ingredientId, _) in recipe.required {
      let key = "ingredient:\(ingredientId)"
      if !keys.contains(key) {
        keys.insert(key)
        if let ingredient = ingredients[ingredientId] {
          names[key] = ingredient.name.lowercased()
        }
      }
    }

    let text = "\(recipe.title)\n\(recipe.instructions)".lowercased()

    // cuisine:<tag> — regional tags only.
    for (bit, tag) in Self.tagBits where Self.cuisineTags.contains(tag) {
      if recipe.tagBitmask & bit != 0 {
        keys.insert("cuisine:\(tag)")
      }
    }

    // time buckets.
    if recipe.timeMinutes <= 15 {
      keys.insert("time:quick")
    } else if recipe.timeMinutes <= 30 {
      keys.insert("time:weeknight")
    } else {
      keys.insert("time:leisurely")
    }

    // technique:<name> — first two keyword classes found in title/instructions.
    var found = 0
    for (name, words) in Self.techniqueKeywords where found < 2 {
      if words.contains(where: { text.contains($0) }) {
        keys.insert("technique:\(name)")
        found += 1
      }
    }

    // spice — one shared class key.
    if Self.spicyPatterns.contains(where: { text.contains($0) }) {
      keys.insert("spice:spicy")
    }

    // nutrient — tag-derived ones first; macro-derived ones below.
    if recipe.tagBitmask & (1 << 10) != 0 {  // low_carb
      keys.insert("nutrient:low_carb")
    }
    if recipe.tagBitmask & (1 << 9) != 0 {  // high_protein
      keys.insert("nutrient:high_protein")
    }

    // tool / other.
    if recipe.tagBitmask & (1 << 11) != 0 {
      keys.insert("tool:one_pot")
    }
    for (bit, tag) in Self.tagBits
    where ["vegetarian", "vegan", "breakfast", "comfort", "budget"].contains(tag) {
      if recipe.tagBitmask & bit != 0 {
        keys.insert("other:\(tag)")
      }
    }

    // Macro-derived nutrient keys (needs per-100 g data).
    let macros = Self.macrosPerServing(recipe: recipe, ingredients: ingredients)
    if let protein = macros["protein"], protein >= 24.0 {
      keys.insert("nutrient:high_protein")
    }
    if let fiber = macros["fiber"], fiber >= 5.0 {
      keys.insert("nutrient:high_fiber")
    }

    for key in keys where names[key] == nil {
      let suffix = key.split(separator: ":", maxSplits: 1).count > 1
        ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
      names[key] = suffix.replacingOccurrences(of: "_", with: " ")
    }

    return (keys.sorted(), names)
  }

  /// NutritionService.macros(for:) port: REQUIRED ingredients only,
  /// (nutrient_per_100g / 100) * grams / servings.
  public static func macrosPerServing(
    recipe: RecipeInput, ingredients: [String: IngredientInput]
  ) -> [String: Double] {
    var cal = 0.0, pro = 0.0, carb = 0.0, fat = 0.0, fib = 0.0, sug = 0.0, sod = 0.0
    for (ingredientId, grams) in recipe.required {
      guard let ingredient = ingredients[ingredientId] else { continue }
      let f = grams / 100.0
      cal += ingredient.calories * f
      pro += ingredient.protein * f
      carb += ingredient.carbs * f
      fat += ingredient.fat * f
      fib += ingredient.fiber * f
      sug += ingredient.sugar * f
      sod += ingredient.sodium * f
    }
    let s = Double(max(recipe.servings, 1))
    return [
      "calories": cal / s, "protein": pro / s, "carbs": carb / s, "fat": fat / s,
      "fiber": fib / s, "sugar": sug / s, "sodium_mg": (sod / s) * 1000.0,
    ]
  }

  /// Extracts features for a whole catalog: recipe id -> sorted feature keys,
  /// plus the feature-key -> display-name map (ingredient names for
  /// `ingredient:` keys, humanized suffixes otherwise).
  public static func extractCatalog(
    recipes: [RecipeInput], ingredients: [String: IngredientInput]
  ) -> (featureKeysByRecipe: [String: [String]], nameOf: [String: String]) {
    let extractor = TasteFeatureExtractor(ingredients: ingredients)
    var featureKeysByRecipe: [String: [String]] = [:]
    var nameOf: [String: String] = [:]
    for recipe in recipes {
      let (keys, names) = extractor.features(for: recipe)
      featureKeysByRecipe[recipe.id] = keys
      for (key, name) in names where nameOf[key] == nil {
        nameOf[key] = name
      }
    }
    return (featureKeysByRecipe, nameOf)
  }
}

// MARK: - Bundled catalog loader (positional data.json)

/// Parses the app's bundled positional `data.json` (schema mirrored from
/// BundledDataLoader) into extractor inputs. Pure Swift so the golden-fixture
/// replay can run against the real bundled catalog.
public enum TasteCatalogLoader {
  /// Ingredient array: [name, cal, protein, carbs, fat, fiber, sugar, sodium,
  /// unit, tip, pairsWith?, notes?]
  /// Recipe array: [id, title, time, servings, required, optional,
  ///                instructions, tagBitmask]
  public static func load(
    data: TasteJSONValue
  ) -> (
    recipes: [TasteFeatureExtractor.RecipeInput],
    ingredients: [String: TasteFeatureExtractor.IngredientInput]
  ) {
    guard case .object(let root) = data else { return ([], [:]) }

    var ingredients: [String: TasteFeatureExtractor.IngredientInput] = [:]
    if case .object(let rawIngredients)? = root["ingredients"] {
      for (idString, value) in rawIngredients {
        guard case .array(let fields) = value, fields.count >= 8,
          let name = fields[0].stringValue,
          let calories = fields[1].doubleValue,
          let protein = fields[2].doubleValue,
          let carbs = fields[3].doubleValue,
          let fat = fields[4].doubleValue,
          let fiber = fields[5].doubleValue,
          let sugar = fields[6].doubleValue,
          let sodium = fields[7].doubleValue
        else { continue }
        ingredients[idString] = TasteFeatureExtractor.IngredientInput(
          id: idString, name: name, calories: calories, protein: protein, carbs: carbs,
          fat: fat, fiber: fiber, sugar: sugar, sodium: sodium)
      }
    }

    var recipes: [TasteFeatureExtractor.RecipeInput] = []
    if case .array(let rawRecipes)? = root["recipes"] {
      for value in rawRecipes {
        guard case .array(let fields) = value, fields.count >= 8,
          let id = fields[0].stringValue,
          let title = fields[1].stringValue,
          let timeMinutes = fields[2].intValue,
          let servings = fields[3].intValue,
          case .array(let requiredRaw) = fields[4],
          case .array(let optionalRaw) = fields[5],
          let instructions = fields[6].stringValue,
          let tagBitmask = fields[7].intValue
        else { continue }
        func pairs(_ raw: [TasteJSONValue]) -> [(id: String, grams: Double)] {
          raw.compactMap { item in
            guard case .array(let pair) = item, pair.count >= 2,
              let id = pair[0].stringValue, let grams = pair[1].doubleValue
            else { return nil }
            return (id, grams)
          }
        }
        recipes.append(
          TasteFeatureExtractor.RecipeInput(
            id: id, title: title, timeMinutes: timeMinutes, servings: servings,
            instructions: instructions, tagBitmask: tagBitmask,
            required: pairs(requiredRaw), optional: pairs(optionalRaw)))
      }
    }

    return (recipes, ingredients)
  }

  /// Convenience: decode and extract in one step.
  public static func loadCatalog(
    data: TasteJSONValue
  ) -> (featureKeysByRecipe: [String: [String]], nameOf: [String: String]) {
    let (recipes, ingredients) = load(data: data)
    return TasteFeatureExtractor.extractCatalog(recipes: recipes, ingredients: ingredients)
  }
}
